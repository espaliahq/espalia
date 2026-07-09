# frozen_string_literal: true

require "test_helper"

# Suggestion discussion-thread commands on the Framework aggregate: posting
# (top-level + replies), author-only edits, soft deletes, and the invariants
# — parent must exist, must not be deleted, must share the suggestion; the
# thread never gates on the suggestion being pending.
class Frameworks::AggregateSuggestionCommentTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Test Framework")

    @cat_id = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
    @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")

    @author_id = SecureRandom.uuid_v7
    @commenter_id = SecureRandom.uuid_v7
    @suggestion_id = SecureRandom.uuid_v7
    @aggregate.suggest_edit(
      @framework_id, @suggestion_id, "capability", @cap_id,
      "description", "Weighs long-term impact", @author_id
    )

    @comment_id = SecureRandom.uuid_v7

    # Drain @unpublished_events accumulated during setup (see
    # aggregate_suggestion_test.rb for why version= is the documented way).
    @aggregate.version = @aggregate.version
  end

  def unpublished
    @aggregate.unpublished_events.to_a
  end

  context "#comment_on_suggestion" do
    should "emit SuggestionCommented with the full payload" do
      @aggregate.comment_on_suggestion(
        @framework_id, @suggestion_id, @comment_id,
        body: "Is 'long-term' the right frame here?", author_id: @commenter_id
      )

      event = unpublished.sole
      assert_instance_of Frameworks::Events::SuggestionCommented, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
      assert_equal @comment_id, event.data[:comment_id]
      assert_equal @commenter_id, event.data[:author_id]
      assert_nil event.data[:parent_id]
    end

    should "accept a reply to an existing comment on the same suggestion" do
      @aggregate.comment_on_suggestion(
        @framework_id, @suggestion_id, @comment_id,
        body: "First", author_id: @commenter_id
      )
      reply_id = SecureRandom.uuid_v7

      @aggregate.comment_on_suggestion(
        @framework_id, @suggestion_id, reply_id,
        body: "Replying", author_id: @author_id, parent_id: @comment_id
      )

      assert_equal @comment_id, unpublished.last.data[:parent_id]
    end

    should "accept a reply to a reply (unbounded depth in data)" do
      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                       body: "First", author_id: @commenter_id)
      reply_id = SecureRandom.uuid_v7
      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, reply_id,
                                       body: "Reply", author_id: @author_id, parent_id: @comment_id)

      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, SecureRandom.uuid_v7,
                                       body: "Reply to reply", author_id: @commenter_id, parent_id: reply_id)

      assert_equal reply_id, unpublished.last.data[:parent_id]
    end

    should "allow commenting on a resolved suggestion" do
      @aggregate.approve_suggestion(@suggestion_id, SecureRandom.uuid_v7)

      @aggregate.comment_on_suggestion(
        @framework_id, @suggestion_id, @comment_id,
        body: "Glad this landed", author_id: @commenter_id
      )

      assert_instance_of Frameworks::Events::SuggestionCommented, unpublished.last
    end

    should "reject an unknown suggestion" do
      error = assert_raises(RuntimeError) do
        @aggregate.comment_on_suggestion(
          @framework_id, SecureRandom.uuid_v7, @comment_id,
          body: "Hello", author_id: @commenter_id
        )
      end
      assert_match(/not found/, error.message)
    end

    should "reject a blank body" do
      assert_raises(RuntimeError) do
        @aggregate.comment_on_suggestion(
          @framework_id, @suggestion_id, @comment_id, body: "   ", author_id: @commenter_id
        )
      end
    end

    should "reject a duplicate comment_id" do
      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                       body: "First", author_id: @commenter_id)

      assert_raises(RuntimeError) do
        @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                         body: "Again", author_id: @commenter_id)
      end
    end

    should "reject a reply to a missing parent" do
      error = assert_raises(RuntimeError) do
        @aggregate.comment_on_suggestion(
          @framework_id, @suggestion_id, @comment_id,
          body: "Reply", author_id: @commenter_id, parent_id: SecureRandom.uuid_v7
        )
      end
      assert_match(/No parent comment/, error.message)
    end

    should "reject a reply to a deleted parent" do
      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                       body: "First", author_id: @commenter_id)
      @aggregate.delete_suggestion_comment(@framework_id, @comment_id, deleted_by_id: @commenter_id)

      assert_raises(RuntimeError) do
        @aggregate.comment_on_suggestion(
          @framework_id, @suggestion_id, SecureRandom.uuid_v7,
          body: "Reply", author_id: @author_id, parent_id: @comment_id
        )
      end
    end

    should "reject a reply whose parent belongs to a different suggestion" do
      other_suggestion = SecureRandom.uuid_v7
      @aggregate.suggest_edit(
        @framework_id, other_suggestion, "capability", @cap_id,
        "name", "Systems Thinking", @author_id
      )
      @aggregate.comment_on_suggestion(@framework_id, other_suggestion, @comment_id,
                                       body: "On the other one", author_id: @commenter_id)

      error = assert_raises(RuntimeError) do
        @aggregate.comment_on_suggestion(
          @framework_id, @suggestion_id, SecureRandom.uuid_v7,
          body: "Cross-thread reply", author_id: @author_id, parent_id: @comment_id
        )
      end
      assert_match(/parent's suggestion/, error.message)
    end
  end

  context "#edit_suggestion_comment" do
    setup do
      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                       body: "Original", author_id: @commenter_id)
    end

    should "emit SuggestionCommentEdited for the author" do
      @aggregate.edit_suggestion_comment(@framework_id, @comment_id,
                                         body: "Revised", edited_by_id: @commenter_id)

      event = unpublished.last
      assert_instance_of Frameworks::Events::SuggestionCommentEdited, event
      assert_equal "Revised", event.data[:body]
    end

    should "reject a non-author editor" do
      error = assert_raises(RuntimeError) do
        @aggregate.edit_suggestion_comment(@framework_id, @comment_id,
                                           body: "Hijack", edited_by_id: @author_id)
      end
      assert_match(/Only the author/, error.message)
    end

    should "reject editing a deleted comment" do
      @aggregate.delete_suggestion_comment(@framework_id, @comment_id, deleted_by_id: @commenter_id)

      assert_raises(RuntimeError) do
        @aggregate.edit_suggestion_comment(@framework_id, @comment_id,
                                           body: "Too late", edited_by_id: @commenter_id)
      end
    end

    should "reject a blank body" do
      assert_raises(RuntimeError) do
        @aggregate.edit_suggestion_comment(@framework_id, @comment_id,
                                           body: "", edited_by_id: @commenter_id)
      end
    end

    should "reject an unknown comment" do
      assert_raises(RuntimeError) do
        @aggregate.edit_suggestion_comment(@framework_id, SecureRandom.uuid_v7,
                                           body: "x", edited_by_id: @commenter_id)
      end
    end
  end

  context "#delete_suggestion_comment" do
    setup do
      @aggregate.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                       body: "Original", author_id: @commenter_id)
    end

    should "emit SuggestionCommentDeleted" do
      @aggregate.delete_suggestion_comment(@framework_id, @comment_id,
                                           deleted_by_id: @commenter_id, reason: "off-topic")

      event = unpublished.last
      assert_instance_of Frameworks::Events::SuggestionCommentDeleted, event
      assert_equal "off-topic", event.data[:reason]
    end

    should "reject deleting twice" do
      @aggregate.delete_suggestion_comment(@framework_id, @comment_id, deleted_by_id: @commenter_id)

      assert_raises(RuntimeError) do
        @aggregate.delete_suggestion_comment(@framework_id, @comment_id, deleted_by_id: @commenter_id)
      end
    end

    should "reject an unknown comment" do
      assert_raises(RuntimeError) do
        @aggregate.delete_suggestion_comment(@framework_id, SecureRandom.uuid_v7,
                                             deleted_by_id: @commenter_id)
      end
    end
  end
end
