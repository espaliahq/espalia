# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

# SuggestionThread materialises suggestion discussion-thread comments:
# post/edit/soft-delete handling, replay idempotency, and the rebuild
# round-trip contract (incl. stable event-carried PKs).
class Frameworks::Projections::SuggestionThreadTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = Frameworks::Projections::SuggestionThread.new
    @framework_id = SecureRandom.uuid_v7
    @suggestion_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, name: "Author")
    end
  end

  context "SuggestionCommented" do
    should "create a comment row keyed by the event-carried comment_id" do
      comment_id = SecureRandom.uuid_v7

      emit(Frameworks::Events::SuggestionCommented,
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: comment_id, parent_id: nil,
        body: "Is this the right frame?", author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        c = FrameworkState::SuggestionComment.find(comment_id)
        assert_equal @framework_id, c.framework_id
        assert_equal @suggestion_id, c.suggestion_id
        assert_equal "Is this the right frame?", c.body
        assert_equal @author.id, c.author_id
        assert_equal "active", c.status
        assert_not_nil c.posted_at
        assert_nil c.parent_id
      end
    end

    should "not resurrect a deleted comment when re-delivered after the delete" do
      comment_id = SecureRandom.uuid_v7
      create_event_data = {
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: comment_id, parent_id: nil,
        body: "Once", author_id: @author.id
      }
      emit(Frameworks::Events::SuggestionCommented, **create_event_data)
      emit(Frameworks::Events::SuggestionCommentDeleted,
        framework_id: @framework_id, comment_id: comment_id,
        deleted_by_id: @author.id, reason: nil)

      # At-least-once delivery / partial re-dispatch of the create.
      emit(Frameworks::Events::SuggestionCommented, **create_event_data)

      ActsAsTenant.with_tenant(@tenant) do
        assert FrameworkState::SuggestionComment.find(comment_id).deleted?
      end
    end

    should "be idempotent when re-processed" do
      comment_id = SecureRandom.uuid_v7
      2.times do
        emit(Frameworks::Events::SuggestionCommented,
          framework_id: @framework_id, suggestion_id: @suggestion_id,
          comment_id: comment_id, parent_id: nil,
          body: "Once", author_id: @author.id)
      end

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 1, FrameworkState::SuggestionComment.count
      end
    end
  end

  context "SuggestionCommentEdited" do
    should "update the body and stamp edited_at/by" do
      comment_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::SuggestionCommented,
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: comment_id, parent_id: nil, body: "Original", author_id: @author.id)

      emit(Frameworks::Events::SuggestionCommentEdited,
        framework_id: @framework_id, comment_id: comment_id,
        body: "Revised", edited_by_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        c = FrameworkState::SuggestionComment.find(comment_id)
        assert_equal "Revised", c.body
        assert_not_nil c.edited_at
        assert_equal @author.id, c.edited_by_id
      end
    end

    should "be a no-op when the row is missing" do
      assert_nothing_raised do
        emit(Frameworks::Events::SuggestionCommentEdited,
          framework_id: @framework_id, comment_id: SecureRandom.uuid_v7,
          body: "x", edited_by_id: @author.id)
      end
    end
  end

  context "SuggestionCommentDeleted" do
    should "soft-delete and stamp metadata" do
      comment_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::SuggestionCommented,
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: comment_id, parent_id: nil, body: "Original", author_id: @author.id)

      emit(Frameworks::Events::SuggestionCommentDeleted,
        framework_id: @framework_id, comment_id: comment_id,
        deleted_by_id: @author.id, reason: "off-topic")

      ActsAsTenant.with_tenant(@tenant) do
        c = FrameworkState::SuggestionComment.find(comment_id)
        assert c.deleted?
        assert_not_nil c.deleted_at
        assert_equal @author.id, c.deleted_by_id
        assert_equal "off-topic", c.deletion_reason
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state incl. ids" do
      top_id = SecureRandom.uuid_v7
      reply_id = SecureRandom.uuid_v7
      doomed_id = SecureRandom.uuid_v7

      append_and_project(Frameworks::Events::SuggestionCommented,
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: top_id, parent_id: nil, body: "Top-level", author_id: @author.id)
      append_and_project(Frameworks::Events::SuggestionCommented,
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: reply_id, parent_id: top_id, body: "Reply", author_id: @author.id)
      append_and_project(Frameworks::Events::SuggestionCommentEdited,
        framework_id: @framework_id, comment_id: top_id,
        body: "Top-level (edited)", edited_by_id: @author.id)
      append_and_project(Frameworks::Events::SuggestionCommented,
        framework_id: @framework_id, suggestion_id: @suggestion_id,
        comment_id: doomed_id, parent_id: nil, body: "Doomed", author_id: @author.id)
      append_and_project(Frameworks::Events::SuggestionCommentDeleted,
        framework_id: @framework_id, comment_id: doomed_id,
        deleted_by_id: @author.id, reason: nil)

      before_snapshot = snapshot_read_models(Frameworks::Projections::SuggestionThread, @tenant)
      assert_equal 3, before_snapshot[:framework_suggestion_comments].size

      Frameworks::Projections::SuggestionThread.reset!(tenant: @tenant)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 0, FrameworkState::SuggestionComment.count
      end

      Projections::Replayer.replay(
        projection_class: Frameworks::Projections::SuggestionThread,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(Frameworks::Projections::SuggestionThread, @tenant)
      assert_equal before_snapshot, after_snapshot
    end
  end

  private

  def emit(event_class, **data)
    @projection.call(build_event(event_class, data))
  end

  def append_and_project(event_class, **data)
    event = build_event(event_class, data)
    Rails.configuration.event_store.append(
      event, stream_name: "tenant-#{@tenant.id}/Framework-#{@framework_id}"
    )
    @projection.call(event)
  end

  def build_event(event_class, data)
    event_class.new(data: data, metadata: { tenant_id: @tenant.id })
  end
end
