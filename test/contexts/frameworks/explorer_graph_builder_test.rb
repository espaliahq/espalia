# frozen_string_literal: true

require "test_helper"

class Frameworks::ExplorerGraphBuilderTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Engineering Growth")

    @role_family_id = SecureRandom.uuid_v7
    @aggregate.add_role_family(@framework_id, @role_family_id, "Engineering", description: "Tech roles")

    @role_id = SecureRandom.uuid_v7
    @aggregate.add_role(@framework_id, @role_id, @role_family_id, "Engineer", "E", "ic")

    @level_id_l1 = SecureRandom.uuid_v7
    @level_id_l2 = SecureRandom.uuid_v7
    @aggregate.add_level(@framework_id, @level_id_l1, @role_id, 1, "Junior", "E1", is_entry: true)
    @aggregate.add_level(@framework_id, @level_id_l2, @role_id, 2, "Senior", "E2")

    @category_id = SecureRandom.uuid_v7
    @aggregate.add_capability_category(@framework_id, @category_id, "Thinking", description: "Cognitive skills", ordinal: 1)

    @capability_id = SecureRandom.uuid_v7
    @capability_stable_id = SecureRandom.uuid_v7
    @aggregate.add_capability(@framework_id, @capability_id, @capability_stable_id, @category_id, "Strategic Thinking", description: "Looking ahead")

    @binding_id = SecureRandom.uuid_v7
    @aggregate.create_capability_role_binding(@framework_id, @binding_id, @capability_id, @role_id)

    @expectation_id = SecureRandom.uuid_v7
    @expectation_stable_id = SecureRandom.uuid_v7
    @aggregate.set_behavioural_expectation(@framework_id, @expectation_id, @expectation_stable_id, @capability_id, 1, "Asks clarifying questions")

    @illustration_id = SecureRandom.uuid_v7
    @illustration_stable_id = SecureRandom.uuid_v7
    @aggregate.add_role_illustration(@framework_id, @illustration_id, @illustration_stable_id, @expectation_id, @role_id, 1, "Runs small spikes")

    @aggregate.publish_version(@framework_id, "seed")
  end

  context "#build on published framework (no open draft)" do
    setup do
      @graph = Frameworks::ExplorerGraphBuilder.new(@aggregate).build
    end

    should "return a Framework value with metadata" do
      assert_equal @framework_id, @graph.framework_id
      assert_equal "Engineering Growth", @graph.name
      assert_equal 1, @graph.current_published_version
      assert_not @graph.draft_in_progress
      assert_nil @graph.draft_version
    end

    should "nest role_families → roles → levels sorted by ordinal" do
      assert_equal 1, @graph.role_families.length
      rf = @graph.role_families.first
      assert_equal "Engineering", rf.name
      assert_equal 1, rf.roles.length
      role = rf.roles.first
      assert_equal "E", role.code
      assert_equal [ 1, 2 ], role.levels.map(&:ordinal)
      assert role.levels.first.is_entry
      assert_not role.levels.first.added_in_draft
    end

    should "nest categories → capabilities → bindings + expectations → illustrations" do
      assert_equal 1, @graph.capability_categories.length
      cat = @graph.capability_categories.first
      assert_equal "Thinking", cat.name
      assert_equal 1, cat.capabilities.length

      cap = cat.capabilities.first
      assert_equal "Strategic Thinking", cap.name
      assert_equal "Looking ahead", cap.description
      assert_equal "active", cap.status
      assert_not cap.added_in_draft
      assert_not cap.pending_archive

      assert_equal 1, cap.bindings.length
      assert_equal @role_id, cap.bindings.first.role_id
      assert_not cap.bindings.first.added_in_draft

      assert_equal 1, cap.expectations.length
      exp = cap.expectations.first
      assert_equal 1, exp.level_ordinal
      assert_equal "Asks clarifying questions", exp.description
      assert_not exp.added_in_draft

      assert_equal 1, exp.illustrations.length
      ill = exp.illustrations.first
      assert_equal "Runs small spikes", ill.description
      assert_equal @role_id, ill.role_id
    end

    should "expose Framework#suggested_edits that delegates to AR" do
      # Without a persisted row this is an empty relation; the point is the
      # interface exists so FocusedSuggestionsQuery keeps working.
      assert_kind_of ActiveRecord::Relation, @graph.suggested_edits
    end
  end

  context "#build mid-draft (shape-changing entities added in v2)" do
    setup do
      @aggregate.start_draft(@framework_id, 2, "author@example.com")

      @new_capability_id = SecureRandom.uuid_v7
      @new_capability_stable_id = SecureRandom.uuid_v7
      @aggregate.add_capability(@framework_id, @new_capability_id, @new_capability_stable_id,
                                @category_id, "Execution", description: "Gets things done")

      @new_binding_id = SecureRandom.uuid_v7
      @aggregate.create_capability_role_binding(@framework_id, @new_binding_id, @new_capability_id, @role_id)

      @new_expectation_id = SecureRandom.uuid_v7
      @new_expectation_stable_id = SecureRandom.uuid_v7
      @aggregate.set_behavioural_expectation(@framework_id, @new_expectation_id, @new_expectation_stable_id,
                                             @new_capability_id, 1, "Ships weekly")

      @new_level_id = SecureRandom.uuid_v7
      @aggregate.add_level(@framework_id, @new_level_id, @role_id, 3, "Staff", "E3")

      @graph = Frameworks::ExplorerGraphBuilder.new(@aggregate).build
    end

    should "flag the new capability as added_in_draft" do
      new_cap = @graph.capability_categories.first.capabilities.find { |c| c.capability_id == @new_capability_id }
      assert new_cap, "expected the draft-only capability in the graph"
      assert new_cap.added_in_draft
      assert_not new_cap.pending_archive
    end

    should "flag the new binding as added_in_draft" do
      new_cap = @graph.capability_categories.first.capabilities.find { |c| c.capability_id == @new_capability_id }
      binding = new_cap.bindings.find { |b| b.binding_id == @new_binding_id }
      assert binding.added_in_draft
    end

    should "flag the new expectation as added_in_draft" do
      new_cap = @graph.capability_categories.first.capabilities.find { |c| c.capability_id == @new_capability_id }
      exp = new_cap.expectations.find { |e| e.expectation_id == @new_expectation_id }
      assert exp.added_in_draft
    end

    should "flag the new level as added_in_draft" do
      role = @graph.role_families.first.roles.first
      new_level = role.levels.find { |l| l.level_id == @new_level_id }
      assert new_level.added_in_draft
    end

    should "leave pre-draft entities unflagged" do
      pre_draft_cap = @graph.capability_categories.first.capabilities
        .find { |c| c.capability_id == @capability_id }
      assert_not pre_draft_cap.added_in_draft
      assert_not pre_draft_cap.bindings.first.added_in_draft
      assert_not pre_draft_cap.expectations.first.added_in_draft
      assert_equal 2, @graph.role_families.first.roles.first.levels
        .reject(&:added_in_draft).length
    end

    should "reflect draft metadata on the framework" do
      assert @graph.draft_in_progress
      assert_equal 2, @graph.draft_version
    end
  end

  context "#build with a capability pending archive" do
    setup do
      @aggregate.start_draft(@framework_id, 2, "author@example.com")
      @aggregate.archive_capability(@framework_id, @capability_id, reason: "test")
      @graph = Frameworks::ExplorerGraphBuilder.new(@aggregate).build
    end

    should "keep status active but flag pending_archive" do
      cap = @graph.capability_categories.first.capabilities.first
      assert_equal "active", cap.status
      assert cap.pending_archive
    end
  end

  context "#build when capability is added-then-archived in same draft" do
    setup do
      @aggregate.start_draft(@framework_id, 2, "author@example.com")

      @throwaway_id = SecureRandom.uuid_v7
      @throwaway_stable = SecureRandom.uuid_v7
      @aggregate.add_capability(@framework_id, @throwaway_id, @throwaway_stable, @category_id,
                                "Throwaway", description: "Added and then archived")
      @aggregate.archive_capability(@framework_id, @throwaway_id, reason: "reconsidered")

      @graph = Frameworks::ExplorerGraphBuilder.new(@aggregate).build
    end

    should "flag as added_in_draft and not pending_archive" do
      cap = @graph.capability_categories.first.capabilities.find { |c| c.capability_id == @throwaway_id }
      assert cap
      assert cap.added_in_draft
      assert_not cap.pending_archive
      # status reflects the raw archive since it was added in this draft —
      # the "pending_archive" convention is specifically for entities that
      # existed before the current draft.
      assert_equal "archived", cap.status
    end
  end
end
