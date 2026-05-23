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

    should "reject reply to a reply (one-level threading invariant)" do
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

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.post_comment(SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          body: "Reply to a reply.", author_id: @author_id,
          capability_stable_id: @capability_stable_id, level_ordinal: 3,
          parent_id: reply_id)
      end
      assert_match(/one-level threading/, err.message)
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
