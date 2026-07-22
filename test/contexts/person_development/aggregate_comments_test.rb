# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::AggregateCommentsTest < ActiveSupport::TestCase
  setup do
    @aggregate = PersonDevelopment::Aggregate.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
    @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
    @author_id = SecureRandom.uuid_v7
    @capability_stable_id = SecureRandom.uuid_v7
  end

  # Shared by the "#post_comment on an evidence linkage" context (a def
  # inside a shoulda context block is not visible to its should blocks).
  def post_link_comment(comment_id: SecureRandom.uuid_v7, level_ordinal: 3,
                        capability_stable_id: @capability_stable_id,
                        evidence_id: @evidence_id, parent_id: nil, body: "Discuss.")
    @aggregate.post_comment(comment_id,
      commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
      body: body, author_id: @author_id,
      capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
      evidence_id: evidence_id, parent_id: parent_id)
  end

  context "#post_comment" do
    should "apply CommentPosted with cell coordinates" do
      comment_id = SecureRandom.uuid_v7
      @aggregate.post_comment(comment_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Nice work.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::CommentPosted, event
      assert_equal comment_id, event.data[:comment_id]
      assert_equal @capability_stable_id, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "Nice work.", event.data[:body]
      assert_nil event.data[:parent_id]
    end

    should "raise when comment_id already exists" do
      comment_id = SecureRandom.uuid_v7
      @aggregate.post_comment(comment_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "First.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)

      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(comment_id,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "dup", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: 3)
      end
    end

    should "reject blank body" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "   ", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: 3)
      end
    end

    should "reject invalid commentable_type" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: "garbage", body: "hi", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: 3)
      end
    end

    should "require cell coords when commentable_type is assessment_cell" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "hi", author_id: @author_id,
          capability_stable_id: nil, level_ordinal: 3)
      end

      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "hi", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: nil)
      end
    end

    should "allow replies to existing comments" do
      parent_id = SecureRandom.uuid_v7
      @aggregate.post_comment(parent_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Top-level.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)

      reply_id = SecureRandom.uuid_v7
      @aggregate.post_comment(reply_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Reply.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3,
        parent_id: parent_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal parent_id, event.data[:parent_id]
    end

    should "reject reply to unknown parent" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "Reply.", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: 3,
          parent_id: SecureRandom.uuid_v7)
      end
    end

    should "allow a reply to a reply, recording the target comment's id" do
      parent_id = SecureRandom.uuid_v7
      reply_id = SecureRandom.uuid_v7
      @aggregate.post_comment(parent_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Top.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)
      @aggregate.post_comment(reply_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Reply.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3,
        parent_id: parent_id)

      reply_to_reply_id = SecureRandom.uuid_v7
      @aggregate.post_comment(reply_to_reply_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Reply to a reply.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3,
        parent_id: reply_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal reply_to_reply_id, event.data[:comment_id]
      assert_equal reply_id, event.data[:parent_id]
    end

    should "reject reply on a different cell than its parent" do
      parent_id = SecureRandom.uuid_v7
      @aggregate.post_comment(parent_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Top.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "Wrong-level reply.", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: 4,
          parent_id: parent_id)
      end
      assert_match(/parent's cell/, err.message)

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "Wrong-cap reply.", author_id: @author_id,
          capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 3,
          parent_id: parent_id)
      end
      assert_match(/parent's cell/, err.message)
    end
  end

  context "#post_comment on an evidence linkage" do
    setup do
      @evidence_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3,
        source: "manager", evidence_type: "observation",
        content: "Handled the incident well.", author_id: @author_id,
        valence: "demonstrated",
        additional_links: [ { capability_stable_id: @capability_stable_id, level_ordinal: 4, valence: "growth_area" } ])
    end

    should "apply CommentPosted carrying the evidence linkage anchor" do
      comment_id = SecureRandom.uuid_v7
      post_link_comment(comment_id: comment_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::CommentPosted, event
      assert_equal PersonDevelopmentComment::EVIDENCE_LINK, event.data[:commentable_type]
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @capability_stable_id, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
    end

    should "require evidence_id" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        post_link_comment(evidence_id: nil)
      end
      assert_match(/evidence_id required/, err.message)
    end

    should "reject unknown evidence" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        post_link_comment(evidence_id: SecureRandom.uuid_v7)
      end
      assert_match(/Unknown evidence/, err.message)
    end

    should "reject a cell the evidence was never linked to" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        post_link_comment(level_ordinal: 7)
      end
      assert_match(/never linked/, err.message)
    end

    should "allow posting after the link is removed (thread stays open)" do
      @aggregate.remove_evidence_link(@evidence_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 4,
        removed_by_id: @author_id)

      post_link_comment(level_ordinal: 4, body: "Removed per the discussion above.")
      event = @aggregate.unpublished_events.to_a.last
      assert_equal 4, event.data[:level_ordinal]
    end

    should "reject posting on withdrawn evidence" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        post_link_comment
      end
      assert_match(/withdrawn/, err.message)
    end

    should "reject a reply that names a different evidence item" do
      other_evidence_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(other_evidence_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3,
        source: "self", evidence_type: "observation",
        content: "Other item.", author_id: @author_id, valence: "demonstrated")

      parent_id = SecureRandom.uuid_v7
      post_link_comment(comment_id: parent_id)

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        post_link_comment(evidence_id: other_evidence_id, parent_id: parent_id)
      end
      assert_match(/parent's evidence linkage/, err.message)
    end

    should "allow replies on the same linkage" do
      parent_id = SecureRandom.uuid_v7
      post_link_comment(comment_id: parent_id)
      post_link_comment(parent_id: parent_id, body: "Reply.")

      event = @aggregate.unpublished_events.to_a.last
      assert_equal parent_id, event.data[:parent_id]
    end
  end

  context "#edit_comment" do
    setup do
      @comment_id = SecureRandom.uuid_v7
      @aggregate.post_comment(@comment_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Original.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)
    end

    should "apply CommentEdited" do
      @aggregate.edit_comment(@comment_id, body: "Updated.", edited_by_id: @author_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::CommentEdited, event
      assert_equal @comment_id, event.data[:comment_id]
      assert_equal "Updated.", event.data[:body]
    end

    should "reject edit by non-author" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.edit_comment(@comment_id, body: "Updated.", edited_by_id: SecureRandom.uuid_v7)
      end
    end

    should "reject blank body" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.edit_comment(@comment_id, body: " ", edited_by_id: @author_id)
      end
    end

    should "reject edit on a deleted comment" do
      @aggregate.delete_comment(@comment_id, deleted_by_id: @author_id)
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.edit_comment(@comment_id, body: "Nope.", edited_by_id: @author_id)
      end
    end
  end

  context "#delete_comment" do
    setup do
      @comment_id = SecureRandom.uuid_v7
      @aggregate.post_comment(@comment_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        body: "Original.", author_id: @author_id,
        capability_stable_id: @capability_stable_id, level_ordinal: 3)
    end

    should "apply CommentDeleted with reason" do
      @aggregate.delete_comment(@comment_id, deleted_by_id: @author_id, reason: "off-topic")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::CommentDeleted, event
      assert_equal "off-topic", event.data[:reason]
    end

    should "reject double-delete" do
      @aggregate.delete_comment(@comment_id, deleted_by_id: @author_id)
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.delete_comment(@comment_id, deleted_by_id: @author_id)
      end
    end

    should "reject delete of unknown comment" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.delete_comment(SecureRandom.uuid_v7, deleted_by_id: @author_id)
      end
    end
  end
end
