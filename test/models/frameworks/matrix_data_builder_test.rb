# frozen_string_literal: true

require "test_helper"

class Frameworks::MatrixDataBuilderTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    framework_id = SecureRandom.uuid_v7

    # Create framework
    @framework = create(:framework_state, framework_id: framework_id)

    # Role family: Engineering
    @eng_family = create(:framework_role_family,
      framework_id: framework_id, name: "Engineering")

    # IC role with 3 levels
    @ic_role = create(:framework_role,
      role_family_id: @eng_family.role_family_id, name: "Software Engineer",
      code: "E", track: "ic")
    @ic_levels = (1..3).map do |i|
      create(:framework_level,
        role_id: @ic_role.role_id, ordinal: i,
        title: "Engineer #{i}", code: "E#{i}")
    end

    # Management role with 2 levels (ordinals 3-4, overlapping IC at 3)
    @mgmt_role = create(:framework_role,
      role_family_id: @eng_family.role_family_id, name: "Engineering Manager",
      code: "EM", track: "management")
    @mgmt_levels = [ 3, 4 ].map do |i|
      create(:framework_level,
        role_id: @mgmt_role.role_id, ordinal: i,
        title: "Manager #{i}", code: "EM#{i}")
    end

    # Second role family: Design
    @design_family = create(:framework_role_family,
      framework_id: framework_id, name: "Design")
    @design_role = create(:framework_role,
      role_family_id: @design_family.role_family_id, name: "Product Designer",
      code: "PD", track: "ic")
    create(:framework_level,
      role_id: @design_role.role_id, ordinal: 1,
      title: "Designer 1", code: "PD1")

    # Capability category + capability bound to Engineering roles
    @category = create(:framework_capability_category,
      framework_id: framework_id, name: "Thinking", ordinal: 1)
    @capability = create(:framework_capability,
      category_id: @category.category_id, name: "Strategic Thinking")

    # Bind to both engineering roles
    create(:framework_capability_role_binding,
      capability_id: @capability.capability_id, role_id: @ic_role.role_id)
    create(:framework_capability_role_binding,
      capability_id: @capability.capability_id, role_id: @mgmt_role.role_id)

    # Expectations at ordinals 1, 2, 3
    @expectations = (1..3).map do |i|
      create(:framework_behavioural_expectation,
        capability_id: @capability.capability_id, level_ordinal: i,
        description: "Level #{i} expectation")
    end

    # Illustrations for IC role at ordinal 1
    create(:framework_role_illustration,
      expectation_id: @expectations[0].expectation_id,
      role_id: @ic_role.role_id, ordinal: 1,
      description: "IC illustration for level 1")

    # Illustrations for mgmt role at ordinal 3
    create(:framework_role_illustration,
      expectation_id: @expectations[2].expectation_id,
      role_id: @mgmt_role.role_id, ordinal: 1,
      description: "Mgmt illustration for level 3")

    # Design-only capability (bound to design role only)
    @design_capability = create(:framework_capability,
      category_id: @category.category_id, name: "Visual Design")
    create(:framework_capability_role_binding,
      capability_id: @design_capability.capability_id, role_id: @design_role.role_id)
    create(:framework_behavioural_expectation,
      capability_id: @design_capability.capability_id, level_ordinal: 1,
      description: "Design expectation at level 1")

    # Reload associations
    @role_families = @framework.role_families.includes(roles: :levels).order(:name)
    @categories = @framework.capability_categories
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "#build" do
    context "with all roles selected" do
      should "merge levels across IC and management roles" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id, @mgmt_role.role_id ])

        ordinals = result[:merged_levels].map { |l| l[:ordinal] }
        assert_equal [ 1, 2, 3, 4 ], ordinals
      end

      should "include role codes for shared ordinals" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id, @mgmt_role.role_id ])

        level_3 = result[:merged_levels].find { |l| l[:ordinal] == 3 }
        role_codes = level_3[:role_codes].map { |rc| rc[:role_code] }.sort
        assert_equal [ "E", "EM" ], role_codes
      end

      should "include capabilities bound to selected roles" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id, @mgmt_role.role_id ])

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_includes cap_names, "Strategic Thinking"
      end

      should "exclude capabilities from other role families" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_not_includes cap_names, "Visual Design"
      end
    end

    context "capability binding marking" do
      should "mark capabilities bound to selected roles as bound_to_selected" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])

        strategic = find_capability(result, "Strategic Thinking")
        assert strategic[:bound_to_selected], "Strategic Thinking should be bound to selected IC role"
      end

      should "mark unbound-but-same-family capabilities as not bound_to_selected" do
        # Create a capability bound only to mgmt but not IC
        mgmt_only_cap = create(:framework_capability,
          category_id: @category.category_id, name: "Team Management")
        create(:framework_capability_role_binding,
          capability_id: mgmt_only_cap.capability_id, role_id: @mgmt_role.role_id)

        # Reload categories
        categories = @framework.capability_categories
          .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
          .order(:ordinal)

        result = build_matrix(selected_role_ids: [ @ic_role.role_id ], categories: categories)

        team_mgmt = find_capability(result, "Team Management")
        assert_not team_mgmt[:bound_to_selected],
          "Team Management should not be bound to selected IC role"
      end
    end

    context "cell building" do
      should "build cells with expectations at matching ordinals" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])

        strategic = find_capability(result, "Strategic Thinking")
        assert_equal 3, strategic[:cells].size
        assert_equal "Level 1 expectation", strategic[:cells][1][:expectation].description
      end

      should "include illustrations filtered by selected roles" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])

        strategic = find_capability(result, "Strategic Thinking")
        cell = strategic[:cells][1]
        assert_equal 1, cell[:illustration_count]
        assert_includes cell[:illustrations_by_role].keys, @ic_role.role_id
      end

      should "exclude illustrations for non-selected roles" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])

        strategic = find_capability(result, "Strategic Thinking")
        cell = strategic[:cells][3]
        # Mgmt illustration at ordinal 3 should be excluded since only IC selected
        assert_equal 0, cell[:illustration_count]
      end
    end

    context "track filter" do
      should "filter to IC roles only" do
        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id, @mgmt_role.role_id ],
          track_filter: "ic"
        )

        role_codes = result[:selected_roles].map(&:code)
        assert_includes role_codes, "E"
        assert_not_includes role_codes, "EM"
      end

      should "filter to management roles only" do
        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id, @mgmt_role.role_id ],
          track_filter: "management"
        )

        role_codes = result[:selected_roles].map(&:code)
        assert_not_includes role_codes, "E"
        assert_includes role_codes, "EM"
      end

      should "echo the active track filter (drives the no-match reset links)" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ], track_filter: "ic")
        assert_equal "ic", result[:track_filter]
      end
    end

    context "empty selection" do
      should "default to all roles when no roles selected" do
        result = build_matrix(selected_role_ids: [])

        # Should include all 3 roles (IC, Mgmt, Design)
        assert_equal 3, result[:selected_roles].size
      end
    end

    context "pending suggestion counts" do
      should "include zero counts when no pending suggestions" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])

        category = result[:categories].first
        assert_equal 0, category[:pending_suggestion_count]
        assert_nil category[:pending_edit]

        cap = category[:capabilities].first
        assert_equal 0, cap[:pending_suggestion_count]
        assert_nil cap[:pending_edit]

        cell = cap[:cells].values.first
        assert_equal 0, cell[:pending_suggestion_count]
        assert_nil cell[:pending_edit]
        assert_empty cell[:illustration_pending_edits]
        assert_empty cell[:illustration_pending_edit_details]
        assert_empty cell[:pending_illustration_creates]
      end

      should "include pending counts and latest edit for expectations" do
        eid = @expectations[0].expectation_id
        pending_map = {
          [ "behavioural_expectation", eid ] => {
            count: 2,
            latest_by_field: { "description" => { suggested_value: "Updated expectation",
                                                  suggestion_id: SecureRandom.uuid_v7,
                                                  created_at: Time.current } }
          }
        }

        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id ],
          pending_suggestions: pending_map
        )

        cap = find_capability(result, "Strategic Thinking")
        cell = cap[:cells][1]
        assert_equal 2, cell[:pending_suggestion_count]
        assert_equal "Updated expectation", cell[:pending_edit][:suggested_value]
        assert_equal 0, cap[:cells][2][:pending_suggestion_count]
        assert_nil cap[:cells][2][:pending_edit]
      end

      should "include pending counts for category and capability" do
        pending_map = {
          [ "capability_category", @category.category_id ] =>
            { count: 1, latest_by_field: { "name" => { suggested_value: "Thinking v2",
                                                       suggestion_id: SecureRandom.uuid_v7,
                                                       created_at: Time.current } } },
          [ "capability", @capability.capability_id ] =>
            { count: 3, latest_by_field: {} }
        }

        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id ],
          pending_suggestions: pending_map
        )

        assert_equal 1, result[:categories].first[:pending_suggestion_count]
        assert_equal "Thinking v2", result[:categories].first[:pending_edit][:suggested_value]

        cap = find_capability(result, "Strategic Thinking")
        assert_equal 3, cap[:pending_suggestion_count]
        assert_nil cap[:pending_edit]
      end

      should "surface the latest pending edit for a category description (its own field)" do
        pending_map = {
          [ "capability_category", @category.category_id ] => {
            count: 1,
            latest_by_field: { "description" => { suggested_value: "How we reason and decide",
                                                  suggestion_id: SecureRandom.uuid_v7,
                                                  created_at: Time.current } }
          }
        }

        result = build_matrix(selected_role_ids: [ @ic_role.role_id ], pending_suggestions: pending_map)
        category = result[:categories].first

        assert_equal "How we reason and decide", category[:description_pending_edit][:suggested_value]
        assert_nil category[:pending_edit], "a description edit must not surface as the name pending_edit"
      end

      should "flag a category holding active capabilities as not archivable" do
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ])
        assert_equal false, result[:categories].first[:archivable]
      end

      should "flag an empty category as archivable (edit mode keeps it visible)" do
        empty = create(:framework_capability_category,
          framework_id: @category.framework_id, name: "Empty", ordinal: 9)
        result = build_matrix(selected_role_ids: [ @ic_role.role_id ], categories: [ empty ], mode: :edit)
        category = result[:categories].find { |c| c[:category].name == "Empty" }
        assert_equal true, category[:archivable]
      end

      should "drop an archived category from the matrix in both modes" do
        archived = create(:framework_capability_category,
          framework_id: @category.framework_id, name: "Gone", ordinal: 9, status: "archived")
        %i[view edit].each do |mode|
          result = build_matrix(selected_role_ids: [ @ic_role.role_id ], categories: [ archived ], mode: mode)
          assert_nil result[:categories].find { |c| c[:category].name == "Gone" },
                     "archived category must not render in #{mode} mode"
        end
      end

      should "surface the latest pending edit for a capability description (its own field)" do
        pending_map = {
          [ "capability", @capability.capability_id ] => {
            count: 1,
            latest_by_field: { "description" => { suggested_value: "Sharper description",
                                                  suggestion_id: SecureRandom.uuid_v7,
                                                  created_at: Time.current } }
          }
        }

        result = build_matrix(selected_role_ids: [ @ic_role.role_id ], pending_suggestions: pending_map)
        cap = find_capability(result, "Strategic Thinking")

        assert_equal "Sharper description", cap[:description_pending_edit][:suggested_value]
        assert_nil cap[:pending_edit], "a description edit must not surface as the name pending_edit"
      end

      should "include illustration pending edit counts and latest edit" do
        illustration = @expectations[0].illustrations.first
        pending_map = {
          [ "role_illustration", illustration.illustration_id ] => {
            count: 1,
            latest_by_field: { "description" => { suggested_value: "Proposed illustration",
                                                  suggestion_id: SecureRandom.uuid_v7,
                                                  created_at: Time.current } }
          }
        }

        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id ],
          pending_suggestions: pending_map
        )

        cap = find_capability(result, "Strategic Thinking")
        cell = cap[:cells][1]
        assert_equal 1, cell[:illustration_pending_edits][illustration.illustration_id]
        assert_equal "Proposed illustration",
          cell[:illustration_pending_edit_details][illustration.illustration_id][:suggested_value]
      end

      should "include pending illustration creates by expectation" do
        suggestion = create(:framework_suggested_edit,
          tenant: @tenant,
          framework_id: @framework.framework_id,
          kind: "create",
          target_entity_type: "role_illustration",
          target_entity_id: nil,
          field: nil,
          current_value: nil,
          suggested_value: nil,
          proposed_attributes: { "role_id" => @ic_role.role_id, "description" => "New example" },
          parent_id: @expectations[0].expectation_id)

        creates_map = { @expectations[0].expectation_id => [ suggestion ] }

        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id ],
          pending_illustration_creates: creates_map
        )

        cap = find_capability(result, "Strategic Thinking")
        pending = cap[:cells][1][:pending_illustration_creates]
        assert_equal 1, pending.size
        assert_equal "New example", pending.first.proposed_attributes["description"]
      end
    end

    context "search filter" do
      should "report no search query and full count when not searching" do
        result = build_matrix(selected_role_ids: [])

        assert_nil result[:search_query]
        assert_equal 2, result[:in_scope_capability_count]
        assert_equal 2, result[:matched_capability_count]
      end

      should "filter by capability name within the role scope" do
        result = build_matrix(selected_role_ids: [], search_query: "visual")

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_equal [ "Visual Design" ], cap_names
        assert_equal "visual", result[:search_query]
        assert_equal 2, result[:in_scope_capability_count]
        assert_equal 1, result[:matched_capability_count]
      end

      should "be case-insensitive" do
        result = build_matrix(selected_role_ids: [], search_query: "VISUAL")

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_equal [ "Visual Design" ], cap_names
      end

      should "match a capability's pending suggested-edit value in edit mode" do
        pending_map = {
          [ "capability", @capability.capability_id ] => {
            count: 1,
            latest_by_field: { "description" => { suggested_value: "Zorkmid proposed text",
                                                  suggestion_id: SecureRandom.uuid_v7, created_at: Time.current } }
          }
        }
        result = build_matrix(selected_role_ids: [], search_query: "zorkmid",
                              pending_suggestions: pending_map, mode: :edit)

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_equal [ "Strategic Thinking" ], cap_names
      end

      should "not match a pending suggested-edit value in view mode" do
        pending_map = {
          [ "capability", @capability.capability_id ] => {
            count: 1,
            latest_by_field: { "description" => { suggested_value: "Zorkmid proposed text",
                                                  suggestion_id: SecureRandom.uuid_v7, created_at: Time.current } }
          }
        }
        result = build_matrix(selected_role_ids: [], search_query: "zorkmid",
                              pending_suggestions: pending_map, mode: :view)

        assert_equal 0, result[:matched_capability_count]
      end

      should "match against expectation text" do
        # "Level 2 expectation" exists only on Strategic Thinking
        result = build_matrix(selected_role_ids: [], search_query: "level 2")

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_includes cap_names, "Strategic Thinking"
        assert_not_includes cap_names, "Visual Design"
      end

      should "not match against illustration text (visible compact surfaces only)" do
        # "illustration" appears only in illustration descriptions, never in a
        # name / description / expectation — so it must not surface anything.
        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id, @mgmt_role.role_id ],
          search_query: "illustration"
        )

        assert_empty result[:categories]
        assert_equal 0, result[:matched_capability_count]
      end

      should "surface every capability in a category whose name matches" do
        # Category is "Thinking" — a query on it surfaces both capabilities
        result = build_matrix(selected_role_ids: [], search_query: "thinking")

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }.sort
        assert_equal [ "Strategic Thinking", "Visual Design" ], cap_names
      end

      should "require every token to match (AND semantics)" do
        result = build_matrix(selected_role_ids: [], search_query: "visual nonexistentword")

        assert_empty result[:categories]
        assert_equal 0, result[:matched_capability_count]
      end

      should "return no categories when nothing matches" do
        result = build_matrix(selected_role_ids: [], search_query: "zzzznomatch")

        assert_empty result[:categories]
        assert_equal 2, result[:in_scope_capability_count]
        assert_equal 0, result[:matched_capability_count]
      end

      should "keep dimmed-but-matching capabilities (search layers over role dimming)" do
        # Team Management is bound to mgmt only — dimmed (not bound_to_selected)
        # when only the IC role is selected, but still in the same family.
        create(:framework_capability,
          category_id: @category.category_id, name: "Team Management").then do |cap|
          create(:framework_capability_role_binding,
            capability_id: cap.capability_id, role_id: @mgmt_role.role_id)
        end
        categories = @framework.capability_categories
          .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
          .order(:ordinal)

        result = build_matrix(
          selected_role_ids: [ @ic_role.role_id ],
          categories: categories,
          search_query: "team"
        )

        team = find_capability(result, "Team Management")
        assert team, "dimmed-but-matching capability should still appear"
        assert_not team[:bound_to_selected], "it stays dimmed — search doesn't change role binding"
      end
    end

    context "empty categories" do
      should "skip categories with no matching capabilities" do
        # Select only design role — Thinking category has "Strategic Thinking" bound to eng only
        # But "Visual Design" IS bound to design, so category should still appear
        result = build_matrix(selected_role_ids: [ @design_role.role_id ])

        cap_names = result[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
        assert_includes cap_names, "Visual Design"
        assert_not_includes cap_names, "Strategic Thinking"
      end
    end
  end

  private

  def build_matrix(selected_role_ids:, track_filter: "both", categories: nil,
                   pending_suggestions: {}, pending_illustration_creates: {},
                   search_query: nil, mode: :view)
    Frameworks::MatrixDataBuilder.new(
      framework: @framework,
      role_families: @role_families,
      categories: categories || @categories,
      selected_role_ids: selected_role_ids,
      track_filter: track_filter,
      mode: mode,
      pending_suggestions: pending_suggestions,
      pending_illustration_creates: pending_illustration_creates,
      search_query: search_query
    ).build
  end

  def find_capability(result, name)
    result[:categories].flat_map { |c| c[:capabilities] }
      .find { |cap| cap[:capability].name == name }
  end
end
