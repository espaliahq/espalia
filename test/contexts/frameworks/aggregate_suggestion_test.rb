# frozen_string_literal: true

require "test_helper"

# Tests for suggestion lifecycle commands on the Framework aggregate.
class Frameworks::AggregateSuggestionTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Test Framework")

    # Create the illustration entity needed for suggestion tests
    rfid = SecureRandom.uuid_v7
    rid = SecureRandom.uuid_v7
    cat_id = SecureRandom.uuid_v7
    cap_id = SecureRandom.uuid_v7
    eid = SecureRandom.uuid_v7
    @ill_id = SecureRandom.uuid_v7

    @aggregate.add_role_family(@framework_id, rfid, "Engineering")
    @aggregate.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
    @aggregate.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
    @aggregate.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
    @aggregate.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
    @aggregate.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7, eid, rid, 1, "Seeks guidance")

    @author_id = SecureRandom.uuid_v7
    @suggestion_id = SecureRandom.uuid_v7

    # Clear unpublished events accumulated during setup so tests only see new events
    @aggregate.unpublished_events.to_a
  end

  # ── suggest_edit ──

  context "#suggest_edit" do
    should "emit EditSuggested" do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "Better wording",
        @author_id
      )

      event = last_event
      assert_kind_of Frameworks::Events::EditSuggested, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
      assert_equal "role_illustration", event.data[:target_entity_type]
      assert_equal @ill_id, event.data[:target_entity_id]
      assert_equal "description", event.data[:field]
      assert_equal "Better wording", event.data[:suggested_value]
      assert_equal @author_id, event.data[:author_id]
    end

    should "raise if suggestion_id already exists" do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "Better wording", @author_id
      )

      assert_raises(RuntimeError, /already exists/) do
        @aggregate.suggest_edit(
          @framework_id, @suggestion_id,
          "role_illustration", @ill_id,
          "description", "Another wording", @author_id
        )
      end
    end

    should "raise if illustration not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.suggest_edit(
          @framework_id, @suggestion_id,
          "role_illustration", SecureRandom.uuid_v7,
          "description", "Text", @author_id
        )
      end
    end

    should "raise for unknown entity type" do
      assert_raises(RuntimeError, /Unknown entity type/) do
        @aggregate.suggest_edit(
          @framework_id, @suggestion_id,
          "unknown_type", @ill_id,
          "description", "Text", @author_id
        )
      end
    end
  end

  # ── amend_suggestion ──

  context "#amend_suggestion" do
    setup do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "First draft", @author_id
      )
    end

    should "emit SuggestionAmended with updated value" do
      @aggregate.amend_suggestion(@suggestion_id, "Revised wording", @author_id)

      event = last_event
      assert_kind_of Frameworks::Events::SuggestionAmended, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
      assert_equal "Revised wording", event.data[:new_suggested_value]
      assert_equal @author_id, event.data[:author_id]
    end

    should "raise if author does not match" do
      other_author = SecureRandom.uuid_v7

      assert_raises(RuntimeError, /Only the author/) do
        @aggregate.amend_suggestion(@suggestion_id, "Revised wording", other_author)
      end
    end

    should "raise if suggestion not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.amend_suggestion(SecureRandom.uuid_v7, "Revised wording", @author_id)
      end
    end
  end

  # ── approve_suggestion ──

  context "#approve_suggestion" do
    setup do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "Approved wording", @author_id
      )
    end

    should "emit SuggestionApproved followed by RoleIllustrationUpdated" do
      reviewer_id = SecureRandom.uuid_v7
      @aggregate.approve_suggestion(@suggestion_id, reviewer_id)

      events = new_events
      approved = events.find { |e| e.is_a?(Frameworks::Events::SuggestionApproved) }
      updated = events.find { |e| e.is_a?(Frameworks::Events::RoleIllustrationUpdated) }

      assert_not_nil approved
      assert_equal @suggestion_id, approved.data[:suggestion_id]
      assert_equal reviewer_id, approved.data[:reviewer_id]

      assert_not_nil updated
      assert_equal @ill_id, updated.data[:illustration_id]
      assert_equal "Approved wording", updated.data[:new_description]
    end

    should "auto-reject competing suggestions on the same field" do
      competing_id = SecureRandom.uuid_v7
      second_author = SecureRandom.uuid_v7
      @aggregate.suggest_edit(
        @framework_id, competing_id,
        "role_illustration", @ill_id,
        "description", "Competing wording", second_author
      )

      reviewer_id = SecureRandom.uuid_v7
      @aggregate.approve_suggestion(@suggestion_id, reviewer_id)

      events = new_events
      rejections = events.select { |e| e.is_a?(Frameworks::Events::SuggestionRejected) }
      assert_equal 1, rejections.size
      assert_equal competing_id, rejections.first.data[:suggestion_id]
      assert_match(/Superseded/, rejections.first.data[:comment])
    end

    should "raise if suggestion not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.approve_suggestion(SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      end
    end
  end

  # ── reject_suggestion ──

  context "#reject_suggestion" do
    should "emit SuggestionRejected" do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "Rejected wording", @author_id
      )
      reviewer_id = SecureRandom.uuid_v7
      @aggregate.reject_suggestion(@suggestion_id, reviewer_id, comment: "Not accurate")

      event = last_event
      assert_kind_of Frameworks::Events::SuggestionRejected, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
      assert_equal reviewer_id, event.data[:reviewer_id]
      assert_equal "Not accurate", event.data[:comment]
    end

    should "raise if suggestion not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.reject_suggestion(SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      end
    end
  end

  # ── withdraw_suggestion ──

  context "#withdraw_suggestion" do
    should "emit SuggestionWithdrawn" do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "To be withdrawn", @author_id
      )
      @aggregate.withdraw_suggestion(@suggestion_id)

      event = last_event
      assert_kind_of Frameworks::Events::SuggestionWithdrawn, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
    end

    should "raise if suggestion not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.withdraw_suggestion(SecureRandom.uuid_v7)
      end
    end
  end

  # ── can_approve? ──

  context "#can_approve?" do
    should "return true for any user (stub until collaborators land)" do
      assert @aggregate.can_approve?(SecureRandom.uuid_v7)
    end
  end

  private

  def new_events
    @aggregate.unpublished_events.to_a
  end

  def last_event
    @aggregate.unpublished_events.to_a.last
  end
end
