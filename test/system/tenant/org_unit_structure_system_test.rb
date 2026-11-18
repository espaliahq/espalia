# frozen_string_literal: true

require "application_system_test_case"

# A unit's own structure from its drawer (#494): giving it one, and moving a
# unit into it, at both widths.
class Tenant::OrgUnitStructureSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
  end

  def overview = ActsAsTenant.with_tenant(@tenant) { OrgGraph::UnitsOverview.new }

  def type_of(key) = overview.then { it.level_of(it.unit(@org[key])).name }

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "give a unit new types from its drawer, and land on its panel in Settings" do
        visit edit_tenant_org_unit_path(@org[:checkout])
        within("#org-unit-structure") { assert_text "Its unit type comes from the top structure." }

        click_link_with_js_fallback "Give it its own structure", expect_selector: "#org-unit-structure-copy"
        click_link_with_js_fallback "New types", expect_selector: "#org-unit-structure-permissive"
        js_fill_in "names[#{@org[:squad]}]", with: "Group"
        assert_no_sideways_overflow
        screenshot("declare_step_#{viewport}")

        click_button_with_js_fallback "Give Checkout its own structure",
                                      expect_text: "Checkout has its own structure. Say here where each of its types can sit."
        within("#org-graph-levels-#{@org[:checkout]}") { assert_text "Group" }
        assert_equal "#org-graph-levels-#{@org[:checkout]}", page.evaluate_script("window.location.hash")
        assert_equal "Group", type_of(:payments)
      end

      should "move a unit into another unit's structure, asking what each of its types becomes" do
        group = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          tenant_user = TenantUser.find_by!(user: @admin_user)
          OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: @admin_user, tenant_user:, person: nil))
                                           .declare_structure(@org[:checkout],
                                                              levels: [ { level_id: group, name: "Group", parent_level_ids: [ group ], top: true } ],
                                                              conversion: { @org[:squad] => group }, effective_on: Date.current)
        end
        visit edit_tenant_org_unit_path(@org[:platform])
        assert_selector "#org-graph-drawer-title", text: "Platform"

        select "Checkout", from: "org-unit-parent"
        # Three forms in the drawer say "Move", so submit the parent's own.
        page.execute_script("document.getElementById('org-unit-parent').form.requestSubmit()")
        assert_selector "#org-unit-move-one-way"
        assert_text "This is one way for now"
        assert_no_sideways_overflow
        screenshot("move_step_#{viewport}")

        click_button_with_js_fallback "Move Platform", expect_text: "Moved."
        assert_equal @org[:checkout], overview.unit(@org[:platform]).parent_id
        assert_equal "Group", type_of(:platform)
      end
    end
  end
end
