# frozen_string_literal: true

require "test_helper"

# Tests for suggestion lifecycle commands on the Framework aggregate.
class Frameworks::AggregateSuggestionTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Test Framework")

    # Create the entity hierarchy needed for suggestion tests
    @rfid = SecureRandom.uuid_v7
    @rid = SecureRandom.uuid_v7
    @lid = SecureRandom.uuid_v7
    @cat_id = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @eid = SecureRandom.uuid_v7
    @ill_id = SecureRandom.uuid_v7

    @aggregate.add_role_family(@framework_id, @rfid, "Engineering")
    @aggregate.add_role(@framework_id, @rid, @rfid, "Software Engineer", "E", "ic")
    @aggregate.add_level(@framework_id, @lid, @rid, 1, "Junior", "E1")
    @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
    @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
    @aggregate.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, @cap_id, 1, "Asks questions")
    @aggregate.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7, @eid, @rid, 1, "Seeks guidance")

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

  # ── tier-2 / tier-3 entity validation on suggest_edit ──

  context "#suggest_edit for tier-2 and tier-3 entities" do
    should "raise if behavioural_expectation not found" do
      assert_raises(RuntimeError, /Expectation .* not found/) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "behavioural_expectation", SecureRandom.uuid_v7,
          "description", "Text", @author_id)
      end
    end

    should "raise if capability not found" do
      assert_raises(RuntimeError, /Capability .* not found/) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "capability", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
    end

    should "raise if capability_category not found" do
      assert_raises(RuntimeError, /Category .* not found/) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "capability_category", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
    end

    should "raise if role not found" do
      assert_raises(RuntimeError, /Role .* not found/) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "role", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
    end

    should "raise if role_family not found" do
      assert_raises(RuntimeError, /Role family .* not found/) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "role_family", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
    end

    should "raise if level not found" do
      assert_raises(RuntimeError, /Level .* not found/) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "level", SecureRandom.uuid_v7,
          "title", "Text", @author_id)
      end
    end

    should "succeed for valid behavioural_expectation" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "behavioural_expectation", @eid, "description", "Better text", @author_id)

      assert_kind_of Frameworks::Events::EditSuggested, last_event
    end

    should "succeed for valid capability" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "capability", @cap_id, "name", "Better name", @author_id)

      assert_kind_of Frameworks::Events::EditSuggested, last_event
    end
  end

  # ── apply_suggested_content_change dispatch ──

  context "#approve_suggestion content dispatch" do
    setup do
      @reviewer_id = SecureRandom.uuid_v7
    end

    should "emit BehaviouralExpectationUpdated for behavioural_expectation/description" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "behavioural_expectation", @eid, "description", "Sharper wording", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::BehaviouralExpectationUpdated) }
      assert_not_nil updated
      assert_equal @eid, updated.data[:expectation_id]
      assert_equal "Sharper wording", updated.data[:new_description]
      assert_match(/Applied via approved suggestion/, updated.data[:rationale])
    end

    should "emit CapabilityUpdated for capability/name" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "capability", @cap_id, "name", "Renamed", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityUpdated) }
      assert_not_nil updated
      assert_equal @cap_id, updated.data[:capability_id]
      assert_equal "Renamed", updated.data[:name]
      assert_not updated.data.key?(:description)
    end

    should "emit CapabilityUpdated for capability/description" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "capability", @cap_id, "description", "New desc", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityUpdated) }
      assert_not_nil updated
      assert_equal "New desc", updated.data[:description]
      assert_not updated.data.key?(:name)
    end

    should "emit CapabilityCategoryUpdated for capability_category/name" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "capability_category", @cat_id, "name", "Renamed Cat", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityCategoryUpdated) }
      assert_not_nil updated
      assert_equal @cat_id, updated.data[:category_id]
      assert_equal "Renamed Cat", updated.data[:name]
    end

    should "emit RoleFamilyUpdated for role_family/description" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "role_family", @rfid, "description", "Builds product", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::RoleFamilyUpdated) }
      assert_not_nil updated
      assert_equal @rfid, updated.data[:role_family_id]
      assert_equal "Builds product", updated.data[:description]
    end

    should "emit RoleUpdated for role/name" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "role", @rid, "name", "Senior Software Engineer", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::RoleUpdated) }
      assert_not_nil updated
      assert_equal @rid, updated.data[:role_id]
      assert_equal "Senior Software Engineer", updated.data[:name]
    end

    should "emit LevelUpdated for level/title" do
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "level", @lid, "title", "Associate", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      updated = new_events.find { |e| e.is_a?(Frameworks::Events::LevelUpdated) }
      assert_not_nil updated
      assert_equal @lid, updated.data[:level_id]
      assert_equal "Associate", updated.data[:title]
    end

    should "auto-reject competing same-field suggestion but spare other-field on same entity" do
      name_sid = @suggestion_id
      desc_sid = SecureRandom.uuid_v7
      competing_name_sid = SecureRandom.uuid_v7

      @aggregate.suggest_edit(@framework_id, name_sid,
        "capability", @cap_id, "name", "Renamed A", @author_id)
      @aggregate.suggest_edit(@framework_id, desc_sid,
        "capability", @cap_id, "description", "Other desc", @author_id)
      @aggregate.suggest_edit(@framework_id, competing_name_sid,
        "capability", @cap_id, "name", "Renamed B", SecureRandom.uuid_v7)

      @aggregate.approve_suggestion(name_sid, @reviewer_id)

      rejections = new_events.select { |e| e.is_a?(Frameworks::Events::SuggestionRejected) }
      rejected_ids = rejections.map { |e| e.data[:suggestion_id] }
      assert_includes rejected_ids, competing_name_sid, "competing name suggestion should be auto-rejected"
      assert_not_includes rejected_ids, desc_sid, "description suggestion on same entity should survive"
    end

    should "raise for unsupported (entity, field) combination" do
      # capability supports name/description but not ordinal — front door allows it through
      # because suggest_edit doesn't validate the field, but the dispatcher's safety net fires.
      @aggregate.suggest_edit(@framework_id, @suggestion_id,
        "capability", @cap_id, "ordinal", "5", @author_id)

      assert_raises(RuntimeError, /Unsupported suggestion target/) do
        @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)
      end
    end
  end

  # ── review_tier ──

  context "#review_tier" do
    should "return tier 1 for role_illustration" do
      assert_equal 1, @aggregate.send(:review_tier, "role_illustration")
    end

    should "return tier 2 for capability and capability_category" do
      assert_equal 2, @aggregate.send(:review_tier, "capability")
      assert_equal 2, @aggregate.send(:review_tier, "capability_category")
    end

    should "return tier 2 for role, role_family, and level" do
      assert_equal 2, @aggregate.send(:review_tier, "role")
      assert_equal 2, @aggregate.send(:review_tier, "role_family")
      assert_equal 2, @aggregate.send(:review_tier, "level")
    end

    should "return tier 3 for behavioural_expectation" do
      assert_equal 3, @aggregate.send(:review_tier, "behavioural_expectation")
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
