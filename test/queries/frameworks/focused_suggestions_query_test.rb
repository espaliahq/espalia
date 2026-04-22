# frozen_string_literal: true

require "test_helper"

class Frameworks::FocusedSuggestionsQueryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @framework = create(:framework_state, tenant: @tenant)
    fwid = @framework.framework_id

    # Two categories, each with two capabilities
    @cat_a = create(:framework_capability_category,
      framework_id: fwid, tenant: @tenant, name: "Thinking")
    @cat_b = create(:framework_capability_category,
      framework_id: fwid, tenant: @tenant, name: "Delivery")

    @cap_a1 = create(:framework_capability,
      category_id: @cat_a.category_id, tenant: @tenant, name: "Strategic Thinking")
    @cap_a2 = create(:framework_capability,
      category_id: @cat_a.category_id, tenant: @tenant, name: "Systems Thinking")
    @cap_b1 = create(:framework_capability,
      category_id: @cat_b.category_id, tenant: @tenant, name: "Delivery Focus")

    # Expectations — two levels for cap_a1, one for cap_a2 & cap_b1
    @exp_a1_l1 = create(:framework_behavioural_expectation,
      capability_id: @cap_a1.capability_id, tenant: @tenant, level_ordinal: 1)
    @exp_a1_l2 = create(:framework_behavioural_expectation,
      capability_id: @cap_a1.capability_id, tenant: @tenant, level_ordinal: 2)
    @exp_a2_l1 = create(:framework_behavioural_expectation,
      capability_id: @cap_a2.capability_id, tenant: @tenant, level_ordinal: 1)
    @exp_b1_l1 = create(:framework_behavioural_expectation,
      capability_id: @cap_b1.capability_id, tenant: @tenant, level_ordinal: 1)

    # Illustrations
    @role_ic  = SecureRandom.uuid_v7
    @role_mgr = SecureRandom.uuid_v7

    @ill_a1_l1_ic = create(:framework_role_illustration,
      expectation_id: @exp_a1_l1.expectation_id, role_id: @role_ic, tenant: @tenant)
    @ill_a1_l2_mgr = create(:framework_role_illustration,
      expectation_id: @exp_a1_l2.expectation_id, role_id: @role_mgr, tenant: @tenant)
    @ill_a2_ic = create(:framework_role_illustration,
      expectation_id: @exp_a2_l1.expectation_id, role_id: @role_ic, tenant: @tenant)
    @ill_b1_ic = create(:framework_role_illustration,
      expectation_id: @exp_b1_l1.expectation_id, role_id: @role_ic, tenant: @tenant)

    # Suggestions, one per leaf entity in each scope
    @sugg_cat_a = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "capability_category",
      target_entity_id: @cat_a.category_id, kind: "edit")
    @sugg_cap_a1 = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "capability",
      target_entity_id: @cap_a1.capability_id, kind: "edit")
    @sugg_cap_a2 = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "capability",
      target_entity_id: @cap_a2.capability_id, kind: "edit")
    @sugg_cap_b1 = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "capability",
      target_entity_id: @cap_b1.capability_id, kind: "edit")
    @sugg_exp_a1_l1 = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "behavioural_expectation",
      target_entity_id: @exp_a1_l1.expectation_id, kind: "edit")
    @sugg_exp_a1_l2 = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "behavioural_expectation",
      target_entity_id: @exp_a1_l2.expectation_id, kind: "edit")
    @sugg_ill_a1_l1_ic = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "role_illustration",
      target_entity_id: @ill_a1_l1_ic.illustration_id, kind: "edit")
    @sugg_ill_a1_l2_mgr = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "role_illustration",
      target_entity_id: @ill_a1_l2_mgr.illustration_id, kind: "edit")
    @sugg_role = create(:framework_suggested_edit,
      tenant: @tenant, framework_id: fwid,
      target_entity_type: "role",
      target_entity_id: SecureRandom.uuid_v7, kind: "edit")
  end

  context "focus: framework" do
    should "return all pending suggestions across entity types" do
      result = Frameworks::FocusedSuggestionsQuery.new(framework: @framework).call
      assert_includes result, @sugg_cat_a
      assert_includes result, @sugg_cap_a1
      assert_includes result, @sugg_cap_b1
      assert_includes result, @sugg_exp_a1_l1
      assert_includes result, @sugg_ill_a1_l1_ic
      assert_includes result, @sugg_role
    end
  end

  context "focus: category" do
    should "return only suggestions nested under the category" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :category, category_id: @cat_a.category_id
      ).call
      assert_includes result, @sugg_cat_a
      assert_includes result, @sugg_cap_a1
      assert_includes result, @sugg_cap_a2
      assert_includes result, @sugg_exp_a1_l1
      assert_includes result, @sugg_exp_a1_l2
      assert_includes result, @sugg_ill_a1_l1_ic
      assert_includes result, @sugg_ill_a1_l2_mgr
      refute_includes result, @sugg_cap_b1
    end

    should "exclude siblings in other categories" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :category, category_id: @cat_a.category_id
      ).call
      refute_includes result, @sugg_cap_b1
    end

    should "exclude top-level entity suggestions (role)" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :category, category_id: @cat_a.category_id
      ).call
      refute_includes result, @sugg_role
    end
  end

  context "focus: capability" do
    should "return only suggestions for the specific capability and its descendants" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :capability, capability_id: @cap_a1.capability_id
      ).call
      assert_includes result, @sugg_cap_a1
      assert_includes result, @sugg_exp_a1_l1
      assert_includes result, @sugg_exp_a1_l2
      assert_includes result, @sugg_ill_a1_l1_ic
      assert_includes result, @sugg_ill_a1_l2_mgr
      refute_includes result, @sugg_cap_a2
      refute_includes result, @sugg_cap_b1
      refute_includes result, @sugg_cat_a
    end
  end

  context "focus: cell" do
    should "return only suggestions for the specific expectation and its illustrations" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :cell,
        capability_id: @cap_a1.capability_id, level_ordinal: 1
      ).call
      assert_includes result, @sugg_exp_a1_l1
      assert_includes result, @sugg_ill_a1_l1_ic
      refute_includes result, @sugg_exp_a1_l2
      refute_includes result, @sugg_ill_a1_l2_mgr
      refute_includes result, @sugg_cap_a2
    end
  end

  context "role filter" do
    should "restrict role_illustration suggestions to selected role" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :capability,
        capability_id: @cap_a1.capability_id, role_ids: [ @role_ic ]
      ).call
      assert_includes result, @sugg_ill_a1_l1_ic
      refute_includes result, @sugg_ill_a1_l2_mgr
    end

    should "not filter non-illustration suggestions by roles" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :capability,
        capability_id: @cap_a1.capability_id, role_ids: [ @role_ic ]
      ).call
      # Capability + expectation entries are unaffected by the roles filter
      assert_includes result, @sugg_cap_a1
      assert_includes result, @sugg_exp_a1_l1
      assert_includes result, @sugg_exp_a1_l2
    end

    should "filter pending role_illustration creates by proposed_attributes role_id" do
      sugg_create_mgr = create(:framework_suggested_edit,
        tenant: @tenant, framework_id: @framework.framework_id,
        target_entity_type: "role_illustration",
        target_entity_id: nil,
        parent_id: @exp_a1_l1.expectation_id,
        kind: "create",
        field: nil, current_value: nil, suggested_value: nil,
        proposed_attributes: { "role_id" => @role_mgr, "description" => "Proposed" })

      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :capability,
        capability_id: @cap_a1.capability_id, role_ids: [ @role_ic ]
      ).call
      refute_includes result, sugg_create_mgr

      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :capability,
        capability_id: @cap_a1.capability_id, role_ids: [ @role_mgr ]
      ).call
      assert_includes result, sugg_create_mgr
    end
  end

  context "invalid focus falls back to framework" do
    should "treat missing capability_id as framework focus" do
      result = Frameworks::FocusedSuggestionsQuery.new(
        framework: @framework, focus: :capability, capability_id: nil
      ).call
      assert_includes result, @sugg_role
      assert_includes result, @sugg_cat_a
    end
  end
end
