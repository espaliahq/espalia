# frozen_string_literal: true

require "test_helper"

class Tenant::CostCentreRulesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  STALE = "The list changed since you opened it, so nothing was saved. Here it is as it stands."

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Admin"))
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member, org_graph_editor: true)
      @family = create(:framework_role_family, tenant: @tenant, name: "Engineering")
      @role = create(:framework_role, tenant: @tenant, role_family_id: @family.role_family_id)
      create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
    end
  end

  def stored = ActsAsTenant.with_tenant(@tenant) { PlanningRuleDefault.find_by(rule: "cost_centre")&.value }

  def entries = TeamPlanning::RuleKinds::CostCentre.entries(stored || { "entries" => [] })

  def labels = entries.pluck("cost_centre")

  def version = Views::Tenant::CostCentreRules::EntryFields.version(entries)

  def add(cost_centre, **fields)
    post tenant_cost_centre_rules_path, params: { version:, entry: { cost_centre:, **fields } }
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show an empty page with the pickers for unit, who and level" do
      get tenant_cost_centre_rules_path

      assert_response :success
      assert_includes response.body, "No cost-centre entries yet"
      assert_select "#cost-centre-entry-unit option[value='#{@org[:payments]}']", text: "Payments"
      assert_select "#cost-centre-entry-reach option[value='family:#{@family.role_family_id}']", text: "Every role in Engineering"
      assert_select "#cost-centre-entry-reach option[value='role:#{@role.role_id}']", text: "Software Engineer"
      assert_select "#cost-centre-entry-level option[value='2']", text: "Level 2"
    end

    should "add entries at the end of the list, saving the tenant's rule" do
      add "Engineering", reach: "family:#{@family.role_family_id}"
      assert_redirected_to tenant_cost_centre_rules_path
      add "Payments", unit_id: @org[:payments], level_ordinal: "2", location: " Fixtureland "

      assert_equal "Entry added for Payments at 2 in the list.", flash[:notice]
      assert_equal [ { "role_family_id" => @family.role_family_id, "cost_centre" => "Engineering" },
                     { "unit_id" => @org[:payments], "level_ordinal" => 2, "location" => "Fixtureland", "cost_centre" => "Payments" } ], entries

      follow_redirect!
      assert_select "#cost-centre-entry-1", text: /Every role in Engineering/
      assert_select "#cost-centre-entry-2", text: /Payments and below · Level 2 · Fixtureland/
    end

    should "show a refused entry again with what was typed" do
      add "", unit_id: @org[:payments], location: "Fixtureland"

      assert_response :unprocessable_content
      assert_includes response.body, "The entry could not be added: Each cost centre entry names a cost centre."
      assert_select "#cost-centre-entry-unit option[selected][value='#{@org[:payments]}']"
      assert_select "#cost-centre-entry-location[value='Fixtureland']"
      assert_nil stored
    end

    should "change an entry in place and remove one" do
      add "Checkout", unit_id: @org[:checkout]
      add "Payments", unit_id: @org[:payments]

      get edit_tenant_cost_centre_rule_path(1, version:)
      assert_response :success
      assert_select "#cost-centre-entry-label[value='Checkout']"

      patch tenant_cost_centre_rule_path(1), params: { version:, entry: { unit_id: @org[:platform], cost_centre: "Platform" } }
      assert_equal "Entry 1 changed.", flash[:notice]
      assert_equal %w[Platform Payments], labels

      delete tenant_cost_centre_rule_path(1), params: { version: }
      assert_equal "Entry 1 removed.", flash[:notice]
      assert_equal %w[Payments], labels
    end

    should "keep a unit, role and level the pickers no longer offer when only the label changes" do
      gone_unit, gone_role = Array.new(2) { SecureRandom.uuid_v7 }
      saved = { "unit_id" => gone_unit, "role_id" => gone_role, "level_ordinal" => 9, "location" => "Alpha", "cost_centre" => "Old" }
      ActsAsTenant.with_tenant(@tenant) { PlanningRuleDefault.create!(rule: "cost_centre", value: { "entries" => [ saved ] }) }

      get edit_tenant_cost_centre_rule_path(1, version:)
      assert_select "#cost-centre-entry-unit option[selected]", count: 1 do
        assert_select "[value=?]", gone_unit
      end
      assert_select "#cost-centre-entry-reach option[selected][value=?]", "role:#{gone_role}"
      assert_select "#cost-centre-entry-level option[selected][value=?]", "9"

      patch tenant_cost_centre_rule_path(1), params: { version:, entry: { unit_id: gone_unit, reach: "role:#{gone_role}", level_ordinal: "9",
                                                                          location: "Alpha", cost_centre: "New" } }
      assert_equal [ saved.merge("cost_centre" => "New") ], entries
    end

    should "flag an entry a later one always overrides" do
      add "Payments", unit_id: @org[:payments]
      add "Checkout", unit_id: @org[:checkout]

      get tenant_cost_centre_rules_path

      assert_select "#cost-centre-entry-shadowed-1", text: "Never used"
      assert_select "[id^='cost-centre-entry-shadowed-']", count: 1
      assert_select "#cost-centre-entry-up-1", count: 0
      assert_select "#cost-centre-entry-down-1[form=cost-centre-entries-move-form]", count: 1
      assert_select "#cost-centre-entries-move-form input[name='version']", count: 1
    end

    should "move an entry up or down a place, and save a dragged order" do
      %w[Alpha Beta Gamma].each { add it, location: it }

      patch reorder_tenant_cost_centre_rules_path, params: { version:, entry: 3, direction: "up" }
      assert_equal "Moved the entry for Gamma to 2 in the list.", flash[:notice]
      assert_equal %w[Alpha Gamma Beta], labels

      patch reorder_tenant_cost_centre_rules_path, params: { version:, entry_ids: %w[3 2 1] }
      assert_equal "Saved the new order.", flash[:notice]
      assert_equal %w[Beta Gamma Alpha], labels
    end

    should "save nothing from a page the list has changed under" do
      add "Alpha", location: "Alpha"
      add "Beta", location: "Beta"
      seen = Views::Tenant::CostCentreRules::EntryFields.version(entries.first(1))

      add "Gamma", location: "Gamma"
      post tenant_cost_centre_rules_path, params: { version: seen, entry: { location: "Delta", cost_centre: "Delta" } }
      assert_equal STALE, flash[:alert]
      patch tenant_cost_centre_rule_path(1), params: { version: seen, entry: { location: "Delta", cost_centre: "Delta" } }
      delete tenant_cost_centre_rule_path(1), params: { version: seen }
      patch reorder_tenant_cost_centre_rules_path, params: { version: seen, entry: 1, direction: "down" }
      assert_equal STALE, flash[:alert]

      patch reorder_tenant_cost_centre_rules_path, params: { version:, entry: 3, direction: "down" }
      patch reorder_tenant_cost_centre_rules_path, params: { version:, entry_ids: %w[1 1 2] }
      get edit_tenant_cost_centre_rule_path(4, version:)
      assert_equal STALE, flash[:alert]
      %w[0 -1 abc].each do |id|
        delete tenant_cost_centre_rule_path(id), params: { version: }
        assert_equal STALE, flash[:alert], "an id of #{id} names no entry, not the last one"
      end
      assert_equal %w[Alpha Beta Gamma], labels
    end
  end

  context "as a member, even an Org Graph editor" do
    setup { sign_in @member_user }

    should "refuse every cost-centre action" do
      get tenant_cost_centre_rules_path
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      post tenant_cost_centre_rules_path, params: { version:, entry: { location: "Alpha", cost_centre: "Alpha" } }
      assert_redirected_to root_path
      patch reorder_tenant_cost_centre_rules_path, params: { version:, entry_ids: [] }
      assert_redirected_to root_path
      assert_nil stored
    end
  end
end
