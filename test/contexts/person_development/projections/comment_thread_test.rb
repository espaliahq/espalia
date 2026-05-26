# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class PersonDevelopment::Projections::CommentThreadTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CommentThread.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, name: "Author")
    end
  end

  context "CommentPosted" do
    should "create a PersonDevelopmentComment row" do
      comment_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::CommentPosted,
        comment_id: comment_id,
        parent_id: nil,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cap_sid,
        level_ordinal: 3,
        body: "Nice work.",
        author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.find(comment_id)
        assert_equal @person_id, c.person_id
        assert_equal @framework_id, c.framework_id
        assert_equal cap_sid, c.capability_stable_id
        assert_equal 3, c.level_ordinal
        assert_equal "Nice work.", c.body
        assert_equal @author.id, c.author_id
        assert_equal "active", c.status
        assert_not_nil c.posted_at
      end
    end
  end

  context "CommentEdited" do
    should "update body and mark edited_at/by" do
      comment_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::CommentPosted,
        comment_id: comment_id, parent_id: nil,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cap_sid, level_ordinal: 3,
        body: "Original.", author_id: @author.id)

      emit(PersonDevelopment::Events::CommentEdited,
        comment_id: comment_id, body: "Updated.", edited_by_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.find(comment_id)
        assert_equal "Updated.", c.body
        assert_not_nil c.edited_at
        assert_equal @author.id, c.edited_by_id
      end
    end

    should "be a no-op when the row is missing" do
      assert_nothing_raised do
        emit(PersonDevelopment::Events::CommentEdited,
          comment_id: SecureRandom.uuid_v7, body: "x", edited_by_id: @author.id)
      end
    end
  end

  context "CommentDeleted" do
    should "soft-delete and stamp metadata" do
      comment_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::CommentPosted,
        comment_id: comment_id, parent_id: nil,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cap_sid, level_ordinal: 3,
        body: "Original.", author_id: @author.id)

      emit(PersonDevelopment::Events::CommentDeleted,
        comment_id: comment_id, deleted_by_id: @author.id, reason: "Off-topic")

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.find(comment_id)
        assert_equal "deleted", c.status
        assert_not_nil c.deleted_at
        assert_equal @author.id, c.deleted_by_id
        assert_equal "Off-topic", c.deletion_reason
      end
    end
  end

  context "FrameworkVersionMigrated" do
    setup do
      @from_stable_id = SecureRandom.uuid_v7
      @to_stable_id   = SecureRandom.uuid_v7
      @comment_id = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::CommentPosted,
        comment_id: @comment_id, parent_id: nil,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: @from_stable_id, level_ordinal: 3,
        body: "Before migration.", author_id: @author.id)
    end

    should "re-key comment rows for a same mapping" do
      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                      mapping_type: "same", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.find(@comment_id)
        assert_equal @to_stable_id, c.capability_stable_id
      end
    end

    should "leave archived-mapping comments where they are" do
      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: nil,
                      mapping_type: "archived", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.find(@comment_id)
        assert_equal @from_stable_id, c.capability_stable_id
        assert_equal "active", c.status
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state" do
      cap_sid = SecureRandom.uuid_v7
      top_id = SecureRandom.uuid_v7
      reply_id = SecureRandom.uuid_v7
      doomed_id = SecureRandom.uuid_v7

      append_and_project(PersonDevelopment::Events::CommentPosted,
        comment_id: top_id, parent_id: nil,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cap_sid, level_ordinal: 3,
        body: "Top-level.", author_id: @author.id)

      append_and_project(PersonDevelopment::Events::CommentPosted,
        comment_id: reply_id, parent_id: top_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cap_sid, level_ordinal: 3,
        body: "Reply.", author_id: @author.id)

      append_and_project(PersonDevelopment::Events::CommentEdited,
        comment_id: top_id, body: "Top-level (edited).", edited_by_id: @author.id)

      append_and_project(PersonDevelopment::Events::CommentPosted,
        comment_id: doomed_id, parent_id: nil,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cap_sid, level_ordinal: 3,
        body: "Doomed.", author_id: @author.id)

      append_and_project(PersonDevelopment::Events::CommentDeleted,
        comment_id: doomed_id, deleted_by_id: @author.id, reason: nil)

      before_snapshot = snapshot_read_models(
        PersonDevelopment::Projections::CommentThread, @tenant)
      assert_equal 3, before_snapshot[:person_development_comments].size

      PersonDevelopment::Projections::CommentThread.reset!(tenant: @tenant)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 0, PersonDevelopmentComment.count
      end

      Projections::Replayer.replay(
        projection_class: PersonDevelopment::Projections::CommentThread,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(
        PersonDevelopment::Projections::CommentThread, @tenant)
      assert_equal before_snapshot, after_snapshot
    end
  end

  private

  def emit(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    @projection.call(event)
  end

  def append_and_project(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
