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

    # Clear unpublished events accumulated during setup so tests only see new events.
    # Setting version= is the documented way to drain @unpublished_events on
    # AggregateRoot — calling .to_a alone does NOT drain the buffer.
    @aggregate.version = @aggregate.version
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

      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(
          @framework_id, @suggestion_id,
          "role_illustration", @ill_id,
          "description", "Another wording", @author_id
        )
      end
      assert_match /already exists/, err.message
    end

    should "raise if illustration not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(
          @framework_id, @suggestion_id,
          "role_illustration", SecureRandom.uuid_v7,
          "description", "Text", @author_id
        )
      end
      assert_match /not found/, err.message
    end

    should "raise for unknown entity type" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(
          @framework_id, @suggestion_id,
          "unknown_type", @ill_id,
          "description", "Text", @author_id
        )
      end
      assert_match /Unknown entity type/, err.message
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

      err = assert_raises(RuntimeError) do
        @aggregate.amend_suggestion(@suggestion_id, "Revised wording", other_author)
      end
      assert_match /Only the author/, err.message
    end

    should "raise if suggestion not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.amend_suggestion(SecureRandom.uuid_v7, "Revised wording", @author_id)
      end
      assert_match /not found/, err.message
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
      err = assert_raises(RuntimeError) do
        @aggregate.approve_suggestion(SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      end
      assert_match /not found/, err.message
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
      err = assert_raises(RuntimeError) do
        @aggregate.reject_suggestion(SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      end
      assert_match /not found/, err.message
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
      @aggregate.withdraw_suggestion(@suggestion_id, @author_id)

      event = last_event
      assert_kind_of Frameworks::Events::SuggestionWithdrawn, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
    end

    should "raise if author does not match" do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "To be withdrawn", @author_id
      )
      other_author = SecureRandom.uuid_v7

      err = assert_raises(RuntimeError) do
        @aggregate.withdraw_suggestion(@suggestion_id, other_author)
      end
      assert_match /Only the author/, err.message
    end

    should "raise if suggestion not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.withdraw_suggestion(SecureRandom.uuid_v7, @author_id)
      end
      assert_match /not found/, err.message
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
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "behavioural_expectation", SecureRandom.uuid_v7,
          "description", "Text", @author_id)
      end
      assert_match /Expectation .* not found/, err.message
    end

    should "raise if capability not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "capability", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
      assert_match /Capability .* not found/, err.message
    end

    should "raise if capability_category not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "capability_category", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
      assert_match /Category .* not found/, err.message
    end

    should "raise if role not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "role", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
      assert_match /Role .* not found/, err.message
    end

    should "raise if role_family not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "role_family", SecureRandom.uuid_v7,
          "name", "Text", @author_id)
      end
      assert_match /Role family .* not found/, err.message
    end

    should "raise if level not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_edit(@framework_id, @suggestion_id,
          "level", SecureRandom.uuid_v7,
          "title", "Text", @author_id)
      end
      assert_match /Level .* not found/, err.message
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

    should "apply the amended value when an amended create suggestion is approved" do
      @aggregate.suggest_create(@framework_id, @suggestion_id, "behavioural_expectation",
        { "level_ordinal" => 2, "description" => "Original wording" }, parent_id: @cap_id, author_id: @author_id)
      @aggregate.amend_suggestion(@suggestion_id, "Amended wording", @author_id)
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      set_event = new_events.find { |e| e.is_a?(Frameworks::Events::BehaviouralExpectationSet) }
      assert_not_nil set_event
      assert_equal "Amended wording", set_event.data[:description], "approval must apply the amended value, not the original"
      assert_equal 2, set_event.data[:level_ordinal]
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

      err = assert_raises(RuntimeError) do
        @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)
      end
      assert_match /Unsupported suggestion target/, err.message
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

  # ── suggest_create ──

  context "#suggest_create" do
    should "emit EntityCreationSuggested for role_illustration" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_illustration",
        { role_id: @rid, description: "Mentors others" },
        parent_id: @eid, author_id: @author_id, rationale: "Worth adding"
      )

      event = last_event
      assert_kind_of Frameworks::Events::EntityCreationSuggested, event
      assert_equal @suggestion_id, event.data[:suggestion_id]
      assert_equal "role_illustration", event.data[:target_entity_type]
      assert_equal @eid, event.data[:parent_id]
      assert_equal @author_id, event.data[:author_id]
      assert_equal "Worth adding", event.data[:rationale]
      assert_equal "Mentors others", event.data[:proposed_attributes][:description]
    end

    should "emit EntityCreationSuggested for behavioural_expectation" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "behavioural_expectation",
        { level_ordinal: 2, description: "New L2 expectation" },
        parent_id: @cap_id, author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityCreationSuggested, last_event
    end

    should "emit EntityCreationSuggested for capability" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability",
        { name: "New Capability" },
        parent_id: @cat_id, author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityCreationSuggested, last_event
    end

    should "emit EntityCreationSuggested for capability_category (no parent)" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability_category",
        { name: "Delivery" },
        parent_id: nil, author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityCreationSuggested, last_event
    end

    should "emit EntityCreationSuggested for role" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role",
        { name: "Engineering Manager", code: "EM", track: "management" },
        parent_id: @rfid, author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityCreationSuggested, last_event
    end

    should "emit EntityCreationSuggested for role_family (no parent)" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_family",
        { name: "Design" },
        parent_id: nil, author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityCreationSuggested, last_event
    end

    should "emit EntityCreationSuggested for level" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "level",
        { ordinal: 2, title: "Mid", code: "E2" },
        parent_id: @rid, author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityCreationSuggested, last_event
    end

    should "raise if suggestion_id already exists" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability_category",
        { name: "First" },
        parent_id: nil, author_id: @author_id
      )

      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "capability_category",
          { name: "Second" },
          parent_id: nil, author_id: @author_id
        )
      end
      assert_match /already exists/, err.message
    end

    should "raise if parent expectation does not exist (illustration)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "role_illustration",
          { role_id: @rid, description: "x" },
          parent_id: SecureRandom.uuid_v7, author_id: @author_id
        )
      end
      assert_match /Expectation .* not found/, err.message
    end

    should "raise if parent capability does not exist (expectation)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "behavioural_expectation",
          { level_ordinal: 1, description: "x" },
          parent_id: SecureRandom.uuid_v7, author_id: @author_id
        )
      end
      assert_match /Capability .* not found/, err.message
    end

    should "raise if parent category does not exist (capability)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "capability",
          { name: "x" },
          parent_id: SecureRandom.uuid_v7, author_id: @author_id
        )
      end
      assert_match /Category .* not found/, err.message
    end

    should "raise if parent role family does not exist (role)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "role",
          { name: "x", code: "X", track: "ic" },
          parent_id: SecureRandom.uuid_v7, author_id: @author_id
        )
      end
      assert_match /Role family .* not found/, err.message
    end

    should "raise if parent role does not exist (level)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "level",
          { ordinal: 5, title: "x", code: "X5" },
          parent_id: SecureRandom.uuid_v7, author_id: @author_id
        )
      end
      assert_match /Role .* not found/, err.message
    end

    should "raise for unknown entity type" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "unknown_type",
          { name: "x" },
          parent_id: nil, author_id: @author_id
        )
      end
      assert_match /Unknown entity type/, err.message
    end

    should "raise if proposed_attributes missing required keys for capability" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "capability",
          { description: "no name" },
          parent_id: @cat_id, author_id: @author_id
        )
      end
      assert_match /Missing proposed_attributes for capability: name/, err.message
    end

    should "raise if proposed_attributes missing required keys for role" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_create(
          @framework_id, @suggestion_id,
          "role",
          { name: "Manager" },
          parent_id: @rfid, author_id: @author_id
        )
      end
      assert_match /Missing proposed_attributes for role/, err.message
    end
  end

  # ── suggest_delete ──

  context "#suggest_delete" do
    should "emit EntityDeletionSuggested for role_illustration" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        author_id: @author_id, rationale: "Outdated"
      )

      event = last_event
      assert_kind_of Frameworks::Events::EntityDeletionSuggested, event
      assert_equal "role_illustration", event.data[:target_entity_type]
      assert_equal @ill_id, event.data[:target_entity_id]
      assert_equal "Outdated", event.data[:rationale]
    end

    should "emit EntityDeletionSuggested for capability" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "capability", @cap_id,
        author_id: @author_id
      )

      assert_kind_of Frameworks::Events::EntityDeletionSuggested, last_event
    end

    should "raise if the same author already has a pending deletion for the entity" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "capability", @cap_id, author_id: @author_id
      )

      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, SecureRandom.uuid_v7,
          "capability", @cap_id, author_id: @author_id
        )
      end
      assert_match /already proposed/, err.message
    end

    should "allow a competing deletion from a different author" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "capability", @cap_id, author_id: @author_id
      )

      # Different authors can still each propose a deletion (auto-reject on
      # approval resolves the competition).
      assert_nothing_raised do
        @aggregate.suggest_delete(
          @framework_id, SecureRandom.uuid_v7,
          "capability", @cap_id, author_id: SecureRandom.uuid_v7
        )
      end
    end

    should "allow the same author to delete a different entity" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "capability", @cap_id, author_id: @author_id
      )

      assert_nothing_raised do
        @aggregate.suggest_delete(
          @framework_id, SecureRandom.uuid_v7,
          "role_illustration", @ill_id, author_id: @author_id
        )
      end
    end

    should "raise if suggestion_id already exists" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id, author_id: @author_id
      )

      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, @suggestion_id,
          "role_illustration", @ill_id, author_id: @author_id
        )
      end
      assert_match /already exists/, err.message
    end

    should "raise if entity not found" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, @suggestion_id,
          "role_illustration", SecureRandom.uuid_v7, author_id: @author_id
        )
      end
      assert_match /Illustration .* not found/, err.message
    end

    should "raise for entity type without delete command (role)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, @suggestion_id,
          "role", @rid, author_id: @author_id
        )
      end
      assert_match /no delete command available/, err.message
    end

    should "raise for entity type without delete command (capability_category)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, @suggestion_id,
          "capability_category", @cat_id, author_id: @author_id
        )
      end
      assert_match /no delete command available/, err.message
    end

    should "raise for entity type without delete command (level)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, @suggestion_id,
          "level", @lid, author_id: @author_id
        )
      end
      assert_match /no delete command available/, err.message
    end

    should "raise for entity type without delete command (behavioural_expectation)" do
      err = assert_raises(RuntimeError) do
        @aggregate.suggest_delete(
          @framework_id, @suggestion_id,
          "behavioural_expectation", @eid, author_id: @author_id
        )
      end
      assert_match /no delete command available/, err.message
    end
  end

  # ── approve_suggestion for create ──

  context "#approve_suggestion for create" do
    setup do
      @reviewer_id = SecureRandom.uuid_v7
    end

    should "emit RoleIllustrationAdded with new ids on illustration approval" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_illustration",
        { role_id: @rid, description: "Mentors juniors" },
        parent_id: @eid, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::RoleIllustrationAdded) }
      assert_not_nil added
      assert_equal @eid, added.data[:expectation_id]
      assert_equal @rid, added.data[:role_id]
      assert_equal "Mentors juniors", added.data[:description]
      # Aggregate generates a fresh illustration_id and stable_id.
      assert_not_equal @ill_id, added.data[:illustration_id]
    end

    should "default ordinal to next-available when not provided" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_illustration",
        { role_id: @rid, description: "Another example" },
        parent_id: @eid, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::RoleIllustrationAdded) }
      # The setup adds one illustration with ordinal 1, so this one should be 2.
      assert_equal 2, added.data[:ordinal]
    end

    should "emit RoleFamilyAdded for role_family creation" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_family", { name: "Design" },
        parent_id: nil, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::RoleFamilyAdded) }
      assert_not_nil added
      assert_equal "Design", added.data[:name]
    end

    should "emit RoleAdded for role creation" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role",
        { name: "EM", code: "EM", track: "management" },
        parent_id: @rfid, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::RoleAdded) }
      assert_not_nil added
      assert_equal @rfid, added.data[:role_family_id]
      assert_equal "EM", added.data[:code]
    end

    should "emit CapabilityCategoryAdded for capability_category creation" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability_category", { name: "Delivery", description: "Ships things" },
        parent_id: nil, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityCategoryAdded) }
      assert_not_nil added
      assert_equal "Delivery", added.data[:name]
    end

    should "emit CapabilityAdded for capability creation (draft is open)" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability", { name: "Resilience" },
        parent_id: @cat_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityAdded) }
      assert_not_nil added
      assert_equal @cat_id, added.data[:category_id]
      assert_equal "Resilience", added.data[:name]
    end

    should "emit LevelAdded for level creation (draft is open)" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "level", { ordinal: 2, title: "Mid", code: "E2" },
        parent_id: @rid, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::LevelAdded) }
      assert_not_nil added
      assert_equal 2, added.data[:ordinal]
    end

    should "emit BehaviouralExpectationSet for expectation creation (draft is open)" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "behavioural_expectation", { level_ordinal: 2, description: "New L2 thing" },
        parent_id: @cap_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      added = new_events.find { |e| e.is_a?(Frameworks::Events::BehaviouralExpectationSet) }
      assert_not_nil added
      assert_equal @cap_id, added.data[:capability_id]
      assert_equal 2, added.data[:level_ordinal]
    end

    should "auto-open an implicit draft when approving capability creation with no draft" do
      # Close the bootstrap v1 draft so the next approval has to open one.
      @aggregate.publish_version(@framework_id, SecureRandom.uuid_v7)

      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability", { name: "Late" },
        parent_id: @cat_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_equal 1, drafts.size, "expected exactly one implicit DraftVersionStarted"
      assert_equal 2, drafts.first.data[:target_version], "draft should target current_version + 1"
      assert_equal @reviewer_id, drafts.first.data[:started_by]
      assert_equal true, drafts.first.data[:auto_opened]

      added = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityAdded) }
      assert_not_nil added, "CapabilityAdded should have been applied inside the implicit draft"
      assert_equal "Late", added.data[:name]
    end

    should "not auto-reject competing creates" do
      other_sid = SecureRandom.uuid_v7

      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_illustration",
        { role_id: @rid, description: "First proposal" },
        parent_id: @eid, author_id: @author_id
      )
      @aggregate.suggest_create(
        @framework_id, other_sid,
        "role_illustration",
        { role_id: @rid, description: "Second proposal" },
        parent_id: @eid, author_id: SecureRandom.uuid_v7
      )

      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      rejections = new_events.select { |e| e.is_a?(Frameworks::Events::SuggestionRejected) }
      assert_empty rejections, "approving a create should not auto-reject other creates"
    end
  end

  # ── approve_suggestion for delete ──

  context "#approve_suggestion for delete" do
    setup do
      @reviewer_id = SecureRandom.uuid_v7
    end

    should "emit RoleIllustrationRemoved for illustration delete" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      removed = new_events.find { |e| e.is_a?(Frameworks::Events::RoleIllustrationRemoved) }
      assert_not_nil removed
      assert_equal @ill_id, removed.data[:illustration_id]
      assert_match(/Applied via approved suggestion/, removed.data[:reason])
    end

    should "emit CapabilityArchived for capability delete (draft is open)" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "capability", @cap_id,
        author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      archived = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityArchived) }
      assert_not_nil archived
      assert_equal @cap_id, archived.data[:capability_id]
    end

    should "auto-open an implicit draft when approving capability delete with no draft" do
      @aggregate.publish_version(@framework_id, SecureRandom.uuid_v7)

      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "capability", @cap_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_equal 1, drafts.size
      assert_equal 2, drafts.first.data[:target_version]
      assert_equal @reviewer_id, drafts.first.data[:started_by]
      assert_equal true, drafts.first.data[:auto_opened]

      archived = new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityArchived) }
      assert_not_nil archived
      assert_equal @cap_id, archived.data[:capability_id]
    end

    should "auto-reject pending edits on the same entity" do
      edit_sid = SecureRandom.uuid_v7
      delete_sid = @suggestion_id

      @aggregate.suggest_edit(
        @framework_id, edit_sid,
        "role_illustration", @ill_id,
        "description", "Better wording", SecureRandom.uuid_v7
      )
      @aggregate.suggest_delete(
        @framework_id, delete_sid,
        "role_illustration", @ill_id,
        author_id: @author_id
      )

      @aggregate.approve_suggestion(delete_sid, @reviewer_id)

      rejections = new_events.select { |e| e.is_a?(Frameworks::Events::SuggestionRejected) }
      rejected_ids = rejections.map { |e| e.data[:suggestion_id] }
      assert_includes rejected_ids, edit_sid, "edit on deleted entity should be auto-rejected"
    end

    should "auto-reject competing pending deletes on the same entity" do
      first_sid = @suggestion_id
      competing_sid = SecureRandom.uuid_v7

      @aggregate.suggest_delete(
        @framework_id, first_sid,
        "role_illustration", @ill_id,
        author_id: @author_id
      )
      @aggregate.suggest_delete(
        @framework_id, competing_sid,
        "role_illustration", @ill_id,
        author_id: SecureRandom.uuid_v7
      )

      @aggregate.approve_suggestion(first_sid, @reviewer_id)

      rejections = new_events.select { |e| e.is_a?(Frameworks::Events::SuggestionRejected) }
      rejected_ids = rejections.map { |e| e.data[:suggestion_id] }
      assert_includes rejected_ids, competing_sid
    end
  end

  # ── approve_suggestion auto-opens draft for shape-changing suggestions ──

  context "#approve_suggestion auto-opens draft for shape-changing suggestions" do
    setup do
      @reviewer_id = SecureRandom.uuid_v7
      # Close the bootstrap v1 draft so further shape-changing approvals
      # need a fresh one. After this, @current_version == 1, no draft.
      @aggregate.publish_version(@framework_id, SecureRandom.uuid_v7)
    end

    should "auto-open draft when approving a behavioural_expectation creation with no draft" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "behavioural_expectation", { level_ordinal: 2, description: "New L2 thing" },
        parent_id: @cap_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_equal 1, drafts.size
      assert_equal true, drafts.first.data[:auto_opened]
      assert_not_nil new_events.find { |e| e.is_a?(Frameworks::Events::BehaviouralExpectationSet) }
    end

    should "auto-open draft when approving a level creation with no draft" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "level", { ordinal: 2, title: "Mid", code: "E2" },
        parent_id: @rid, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_equal 1, drafts.size
      assert_equal true, drafts.first.data[:auto_opened]
      assert_not_nil new_events.find { |e| e.is_a?(Frameworks::Events::LevelAdded) }
    end

    should "join an existing implicit draft when approving a second shape-changing suggestion" do
      first_sid = @suggestion_id
      second_sid = SecureRandom.uuid_v7
      second_reviewer = SecureRandom.uuid_v7

      @aggregate.suggest_create(
        @framework_id, first_sid,
        "capability", { name: "First New Cap" },
        parent_id: @cat_id, author_id: @author_id
      )
      @aggregate.suggest_create(
        @framework_id, second_sid,
        "capability", { name: "Second New Cap" },
        parent_id: @cat_id, author_id: SecureRandom.uuid_v7
      )

      @aggregate.approve_suggestion(first_sid, @reviewer_id)
      @aggregate.approve_suggestion(second_sid, second_reviewer)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_equal 1, drafts.size, "second approval should join the draft, not open a new one"
      assert_equal @reviewer_id, drafts.first.data[:started_by],
                   "draft owner is the first approver"

      added = new_events.select { |e| e.is_a?(Frameworks::Events::CapabilityAdded) }
      assert_equal 2, added.size, "both capabilities should land in the same draft"
    end

    should "join an explicit draft when approving a shape-changing suggestion inside it" do
      explicit_starter = SecureRandom.uuid_v7
      @aggregate.start_draft(@framework_id, 2, explicit_starter)

      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "capability", { name: "Joined" },
        parent_id: @cat_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_equal 1, drafts.size, "should not open a second draft on top of the explicit one"
      assert_equal explicit_starter, drafts.first.data[:started_by]
      assert_nil drafts.first.data[:auto_opened],
                 "explicit start_draft does not set auto_opened"
      assert_not_nil new_events.find { |e| e.is_a?(Frameworks::Events::CapabilityAdded) }
    end

    should "not open a draft when approving a shape-preserving creation" do
      @aggregate.suggest_create(
        @framework_id, @suggestion_id,
        "role_illustration",
        { role_id: @rid, description: "Mentors juniors" },
        parent_id: @eid, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_empty drafts, "shape-preserving suggestions must not auto-open a draft"
      assert_not_nil new_events.find { |e| e.is_a?(Frameworks::Events::RoleIllustrationAdded) }
    end

    should "not open a draft when approving a shape-preserving deletion (illustration)" do
      @aggregate.suggest_delete(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id, author_id: @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_empty drafts
      assert_not_nil new_events.find { |e| e.is_a?(Frameworks::Events::RoleIllustrationRemoved) }
    end

    should "not open a draft when approving an :edit suggestion (always shape-preserving)" do
      @aggregate.suggest_edit(
        @framework_id, @suggestion_id,
        "role_illustration", @ill_id,
        "description", "Better wording", @author_id
      )
      @aggregate.approve_suggestion(@suggestion_id, @reviewer_id)

      drafts = new_events.select { |e| e.is_a?(Frameworks::Events::DraftVersionStarted) }
      assert_empty drafts
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
