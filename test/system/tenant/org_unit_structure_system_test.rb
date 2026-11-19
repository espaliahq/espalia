# frozen_string_literal: true

require "application_system_test_case"

# A unit's own structure from its drawer (#494): giving it one, and moving a
# unit into it and back out (#521), at both widths.
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

  def own_types(key) = overview.structures.fetch(@org[key], []).map(&:name)

  def top_types = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.pluck(:name) }

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "give a unit new types from its drawer, and land on its panel in Settings" do
        visit edit_tenant_org_unit_path(@org[:checkout])
        within("#org-unit-structure") { assert_text "Its unit type comes from the organisation's structure." }

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
        assert_selector "select[name='conversion[#{@org[:team]}]']"
        assert_no_text "one way"
        assert_no_sideways_overflow
        screenshot("move_step_#{viewport}")

        click_button_with_js_fallback "Move Platform", expect_text: "Moved Platform into Checkout's structure. Its type is now Group."
        screenshot("moved_#{viewport}")
        assert_equal @org[:checkout], overview.unit(@org[:platform]).parent_id
        assert_equal "Group", type_of(:platform)
      end

      should "move a unit back out of a structure, each type preselected as it was before (#521)" do
        group = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          tenant_user = TenantUser.find_by!(user: @admin_user)
          structure = OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: @admin_user, tenant_user:, person: nil))
          structure.declare_structure(@org[:checkout], levels: [ { level_id: group, name: "Group", parent_level_ids: [ group ], top: true } ],
                                                       conversion: { @org[:squad] => group }, effective_on: Date.current)
          structure.move_unit(@org[:platform], @org[:checkout], conversion: { @org[:team] => group }, effective_on: Date.current)
        end
        visit edit_tenant_org_unit_path(@org[:platform])
        assert_selector "#org-graph-drawer-title", text: "Platform"

        select "Engineering", from: "org-unit-parent"
        page.execute_script("document.getElementById('org-unit-parent').form.requestSubmit()")
        assert_text "takes it out of Checkout's structure into the organisation's structure"
        assert_equal "Team", find("select[name='conversion[#{group}]']").find("option[selected]").text
        assert_no_sideways_overflow
        screenshot("move_out_step_#{viewport}")

        click_button_with_js_fallback "Move Platform", expect_text: "Moved Platform into the organisation's structure. Its type is now Team."
        assert_equal [ @org[:engineering], @org[:team] ], overview.unit(@org[:platform]).then { [ it.parent_id, it.level_id ] }
      end

      should "move a unit out of a structure to the top of the organisation's (#521)" do
        group = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          tenant_user = TenantUser.find_by!(user: @admin_user)
          OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: @admin_user, tenant_user:, person: nil))
                                           .declare_structure(@org[:checkout],
                                                              levels: [ { level_id: group, name: "Group", parent_level_ids: [ group ], top: true } ],
                                                              conversion: { @org[:squad] => group }, effective_on: Date.current)
        end
        visit edit_tenant_org_unit_path(@org[:payments])
        assert_selector "#org-graph-drawer-title", text: "Payments"

        select "None (at the top)", from: "org-unit-parent"
        page.execute_script("document.getElementById('org-unit-parent').form.requestSubmit()")
        assert_text "Moving Payments to the top of the organisation's structure takes it out of Checkout's structure"
        assert_equal "Squad", find("select[name='conversion[#{group}]']").find("option[selected]").text
        assert_no_sideways_overflow
        screenshot("move_to_top_step_#{viewport}")

        click_button_with_js_fallback "Move Payments", expect_text: "Moved Payments into the organisation's structure. Its type is now Squad."
        assert_equal [ nil, @org[:squad] ], overview.unit(@org[:payments]).then { [ it.parent_id, it.level_id ] }
      end

      # #494's worked example: a copy of the types in force, a unit moved into
      # it, and the tenant-wide type nothing holds any more removed.
      should "copy the structure in force, move a unit into it, and remove the tenant-wide type left behind" do
        visit edit_tenant_org_unit_path(@org[:checkout])
        click_link_with_js_fallback "Give it its own structure", expect_selector: "#org-unit-structure-copy"
        within("#org-unit-structure-copy") { assert_text "Department, Team, and Squad" }
        assert_no_sideways_overflow
        screenshot("copy_step_#{viewport}")
        click_button_with_js_fallback "Give Checkout its own structure", expect_selector: "#org-graph-levels-#{@org[:checkout]}"
        assert_equal [ %w[Department Team Squad], "Squad" ], [ own_types(:checkout), type_of(:payments) ]
        assert_not_equal @org[:squad], overview.unit(@org[:payments]).level_id

        visit edit_tenant_org_unit_path(@org[:platform])
        select "Checkout", from: "org-unit-parent"
        page.execute_script("document.getElementById('org-unit-parent').form.requestSubmit()")
        assert_selector "select[name='conversion[#{@org[:team]}]']"
        select "Squad", from: "conversion[#{@org[:team]}]"
        click_button_with_js_fallback "Move Platform", expect_text: "Moved Platform into Checkout's structure. Its type is now Squad."

        visit tenant_org_graph_settings_path
        click_button_with_js_fallback("org-graph-level-menu-#{@org[:squad]}", expect_selector: "#org-graph-level-remove-#{@org[:squad]}")
        click_button_with_js_fallback("org-graph-level-remove-#{@org[:squad]}", expect_selector: "#org-graph-remove-level-#{@org[:squad]}")
        click_button_with_js_fallback("org-graph-level-remove-confirm-#{@org[:squad]}", expect_text: "Squad is no longer a unit type.")
        assert_no_sideways_overflow
        screenshot("tenant_wide_type_removed_#{viewport}")

        assert_equal [ %w[Department Team], %w[Department Team Squad] ], [ top_types, own_types(:checkout) ]
        assert_equal [ "Team", "Squad", "Squad" ], %i[checkout platform payments].map { type_of(it) }
      end
    end
  end
end
