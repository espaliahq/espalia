# frozen_string_literal: true

require "test_helper"

# Exercises the `mode: :view | :edit` filter on {Frameworks::MatrixDataBuilder}.
# The existing matrix_data_builder_test.rb covers the main behaviour against
# AR records; this file uses ExplorerGraph value objects so we can set
# `added_in_draft: true` explicitly on individual nodes and confirm the
# filter surfaces them in edit mode but hides them in view.
class Frameworks::MatrixDataBuilderModeTest < ActiveSupport::TestCase
  include Frameworks::ExplorerGraph

  setup do
    @role_id = SecureRandom.uuid_v7
    @draft_level_id = SecureRandom.uuid_v7
    @live_level_id = SecureRandom.uuid_v7

    @live_level = Level.new(level_id: @live_level_id, role_id: @role_id, ordinal: 1,
                            title: "L1", code: "R1", is_entry: true, added_in_draft: false)
    @draft_level = Level.new(level_id: @draft_level_id, role_id: @role_id, ordinal: 2,
                             title: "L2", code: "R2", is_entry: false, added_in_draft: true)

    @role = Role.new(role_id: @role_id, role_family_id: SecureRandom.uuid_v7,
                     name: "Engineer", code: "R", track: "ic",
                     levels: [ @live_level, @draft_level ])
    @role_family = RoleFamily.new(role_family_id: @role.role_family_id,
                                  name: "Engineering", description: nil,
                                  department: nil, roles: [ @role ])

    @cap_id = SecureRandom.uuid_v7
    @draft_cap_id = SecureRandom.uuid_v7
    @draft_binding_id = SecureRandom.uuid_v7
    @draft_exp_id = SecureRandom.uuid_v7

    # Live capability with a live binding + live expectation at level 1
    @live_expectation = BehaviouralExpectation.new(
      expectation_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
      capability_id: @cap_id, level_ordinal: 1, description: "live expectation",
      illustrations: [], added_in_draft: false
    )
    @live_binding = CapabilityRoleBinding.new(
      binding_id: SecureRandom.uuid_v7, capability_id: @cap_id,
      role_id: @role_id, weight: 1.0, individual_tolerance: nil,
      added_in_draft: false
    )
    # Draft expectation at level 2 (visible only in edit mode)
    @draft_expectation = BehaviouralExpectation.new(
      expectation_id: @draft_exp_id, stable_id: SecureRandom.uuid_v7,
      capability_id: @cap_id, level_ordinal: 2, description: "draft expectation",
      illustrations: [], added_in_draft: true
    )
    @live_cap = Capability.new(
      capability_id: @cap_id, stable_id: SecureRandom.uuid_v7,
      category_id: SecureRandom.uuid_v7, name: "Live Capability",
      description: "A live capability",
      status: "active",
      bindings: [ @live_binding ],
      expectations: [ @live_expectation, @draft_expectation ],
      added_in_draft: false, pending_archive: false
    )

    # Entirely draft-only capability
    @draft_cap_binding = CapabilityRoleBinding.new(
      binding_id: @draft_binding_id, capability_id: @draft_cap_id,
      role_id: @role_id, weight: 1.0, individual_tolerance: nil,
      added_in_draft: true
    )
    @draft_cap = Capability.new(
      capability_id: @draft_cap_id, stable_id: SecureRandom.uuid_v7,
      category_id: @live_cap.category_id, name: "Draft Capability",
      description: "A capability added in a draft",
      status: "active",
      bindings: [ @draft_cap_binding ],
      expectations: [],
      added_in_draft: true, pending_archive: false
    )

    @category = CapabilityCategory.new(
      category_id: @live_cap.category_id, name: "Thinking",
      description: nil, ordinal: 1, deficit_threshold: nil,
      overperformance_cap: nil, status: "active",
      capabilities: [ @live_cap, @draft_cap ]
    )
  end

  context "mode: :view" do
    setup do
      @result = build(mode: :view)
    end

    should "hide capabilities flagged added_in_draft" do
      cap_names = @result[:categories].flat_map { |c| c[:capabilities] }.map { |c| c[:capability].name }
      assert_includes cap_names, "Live Capability"
      assert_not_includes cap_names, "Draft Capability"
    end

    should "hide levels flagged added_in_draft from merged levels" do
      ordinals = @result[:merged_levels].map { |l| l[:ordinal] }
      assert_equal [ 1 ], ordinals
    end

    should "hide expectations flagged added_in_draft from cells" do
      cap_row = @result[:categories].first[:capabilities].find { |c| c[:capability].name == "Live Capability" }
      assert_not_nil cap_row[:cells][1]
      assert_nil cap_row[:cells][2], "draft expectation at level 2 should be hidden in view mode"
    end
  end

  context "mode: :edit" do
    setup do
      @result = build(mode: :edit)
    end

    should "include capabilities flagged added_in_draft" do
      cap_names = @result[:categories].flat_map { |c| c[:capabilities] }.map { |c| c[:capability].name }
      assert_includes cap_names, "Live Capability"
      assert_includes cap_names, "Draft Capability"
    end

    should "include draft-only levels in merged levels" do
      ordinals = @result[:merged_levels].map { |l| l[:ordinal] }
      assert_equal [ 1, 2 ], ordinals
    end

    should "include draft expectations in cells" do
      cap_row = @result[:categories].first[:capabilities].find { |c| c[:capability].name == "Live Capability" }
      assert_not_nil cap_row[:cells][2], "draft expectation at level 2 should appear in edit mode"
    end
  end

  context "empty categories" do
    setup do
      @empty_category = CapabilityCategory.new(
        category_id: SecureRandom.uuid_v7, name: "Brand New", description: nil,
        ordinal: 2, deficit_threshold: nil, overperformance_cap: nil,
        status: "active", capabilities: []
      )
    end

    should "keep an empty category in edit mode (so it can be populated)" do
      names = build_with([ @category, @empty_category ], mode: :edit)[:categories].map { |c| c[:category].name }
      assert_includes names, "Brand New"
    end

    should "drop an empty category in view mode" do
      names = build_with([ @category, @empty_category ], mode: :view)[:categories].map { |c| c[:category].name }
      assert_not_includes names, "Brand New"
    end
  end

  context "authorable empty cells" do
    setup do
      # A role with two *live* levels (avoids the draft-level confound), a
      # capability bound to it with an expectation only at level 1 — so level 2
      # is empty-but-applicable.
      role_id = SecureRandom.uuid_v7
      levels = [
        Level.new(level_id: SecureRandom.uuid_v7, role_id: role_id, ordinal: 1,
                  title: "L1", code: "R1", is_entry: true, added_in_draft: false),
        Level.new(level_id: SecureRandom.uuid_v7, role_id: role_id, ordinal: 2,
                  title: "L2", code: "R2", is_entry: false, added_in_draft: false)
      ]
      role = Role.new(role_id: role_id, role_family_id: SecureRandom.uuid_v7,
                      name: "Engineer", code: "R", track: "ic", levels: levels)
      @gap_family = RoleFamily.new(role_family_id: role.role_family_id, name: "Engineering",
                                   description: nil, department: nil, roles: [ role ])
      @gap_role_id = role_id

      @gap_cap_id = SecureRandom.uuid_v7
      gap_binding = CapabilityRoleBinding.new(binding_id: SecureRandom.uuid_v7, capability_id: @gap_cap_id,
                                              role_id: role_id, weight: 1.0, individual_tolerance: nil,
                                              added_in_draft: false)
      gap_exp = BehaviouralExpectation.new(expectation_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
                                           capability_id: @gap_cap_id, level_ordinal: 1, description: "only level 1",
                                           illustrations: [], added_in_draft: false)
      gap_cap = Capability.new(capability_id: @gap_cap_id, stable_id: SecureRandom.uuid_v7,
                               category_id: SecureRandom.uuid_v7, name: "Gap Capability", description: nil,
                               status: "active", bindings: [ gap_binding ], expectations: [ gap_exp ],
                               added_in_draft: false, pending_archive: false)
      @gap_category = CapabilityCategory.new(category_id: gap_cap.category_id, name: "Thinking", description: nil,
                                             ordinal: 1, deficit_threshold: nil, overperformance_cap: nil,
                                             status: "active", capabilities: [ gap_cap ])
    end

    should "emit an authorable placeholder for the empty applicable cell in edit mode" do
      cap = build_gap(mode: :edit)[:categories].first[:capabilities].first
      assert_not_nil cap[:cells][1][:expectation], "level 1 is authored"
      assert cap[:cells][2][:authorable], "level 2 is empty-but-applicable"
      assert_nil cap[:cells][2][:expectation]
      assert_equal @gap_cap_id, cap[:cells][2][:capability_id]
    end

    should "leave the empty applicable cell nil in view mode" do
      cap = build_gap(mode: :view)[:categories].first[:capabilities].first
      assert_nil cap[:cells][2], "no authoring placeholder in view mode"
    end
  end

  private

  def build(mode:)
    build_with([ @category ], mode: mode)
  end

  def build_gap(mode:)
    Frameworks::MatrixDataBuilder.new(
      framework: Framework.new(
        framework_id: SecureRandom.uuid_v7, name: "Test",
        current_published_version: 1, draft_in_progress: true, draft_version: 2,
        role_families: [ @gap_family ], capability_categories: [ @gap_category ]
      ),
      role_families: [ @gap_family ], categories: [ @gap_category ],
      selected_role_ids: [ @gap_role_id ], mode: mode
    ).build
  end

  def build_with(categories, mode:)
    Frameworks::MatrixDataBuilder.new(
      framework: Framework.new(
        framework_id: SecureRandom.uuid_v7, name: "Test",
        current_published_version: 1, draft_in_progress: true,
        draft_version: 2,
        role_families: [ @role_family ],
        capability_categories: categories
      ),
      role_families: [ @role_family ],
      categories: categories,
      selected_role_ids: [ @role_id ],
      mode: mode
    ).build
  end
end
