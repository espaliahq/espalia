# frozen_string_literal: true

require "application_system_test_case"

# A structure declared since a plan's base reads as one drift row
# ([#494](https://github.com/espaliahq/espalia/issues/494)), naming the
# declaring unit only to a plan that covers it. A move between structures
# folds the same way ([#521](https://github.com/espaliahq/espalia/issues/521)).
class PlanChangesStructureSystemTest < ApplicationSystemTestCase
  ROW = "[data-drift-change='structure_declared']"
  MOVE = "[data-drift-change='moved_between_structures']"

  setup do
    @tenant = create(:tenant)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    department, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @checkout, @cards, wallet, @ledger = Array.new(5) { SecureRandom.uuid_v7 }

    travel_to(30.days.ago) do
      since = Date.current.iso8601
      ActsAsTenant.with_tenant(@tenant) do
        @admin = create(:tenant_user, tenant: @tenant, role: :admin, team_planner: true,
                                      user: create(:user, password: TEST_PASSWORD), person: create(:person, tenant: @tenant))
        structure.define_taxonomy([ { level_id: department, name: "Department" },
                                    { level_id: @squad, name: "Squad", parent_level_ids: [ department ], top: false } ], effective_on: since)
        structure.set_kind_parents(@squad, parent_ids: [ department, @squad ], top: false, effective_on: since)
        structure.create_unit(@engineering, "Engineering", level_id: department, effective_on: since)
        structure.create_unit(@checkout, "Checkout", level_id: @squad, parent_id: @engineering, effective_on: since)
        structure.create_unit(@cards, "Cards", level_id: @squad, parent_id: @checkout, effective_on: since)
        structure.create_unit(wallet, "Wallet", level_id: @squad, parent_id: @checkout, effective_on: since)
        structure.create_unit(@ledger, "Ledger", level_id: @squad, parent_id: @engineering, effective_on: since)
      end
    end

    @whole = call(Operations::TeamPlanning::CreatePlan, name: "Everyone next year", base_on: Date.current.iso8601)[:plan_id]
    @cards_only = call(Operations::TeamPlanning::CreatePlan, name: "Cards next year", base_on: Date.current.iso8601,
                                                             unit_ids: [ @cards ])[:plan_id]
    call(Operations::OrgGraph::DeclareStructure, unit_id: @checkout, levels: [ { name: "Pod", parent_names: %w[pod], top: true } ],
                                                 conversion: { @squad => "Pod" })
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "read a declaration as one row, naming the unit to a plan that covers it" do
      sign_in_as(@admin.user)
      visit changes_plan_path(@whole)

      assert_selector ROW, count: 1, text: "Checkout was given its own structure: 2 units changed type"
      assert_no_selector "[data-drift-change='unit_kind_changed']"

      visit changes_plan_path(@cards_only)
      assert_selector ROW, count: 1, text: "The structure above this plan changed: 1 unit changed type"
      assert_no_text "Checkout"
    end

    should "read a move into a structure as one row, naming the structure to a plan that covers it" do
      move_ledger_in
      sign_in_as(@admin.user)
      visit changes_plan_path(@whole)

      assert_selector MOVE, count: 1, text: "Ledger moved into Checkout's structure: 1 unit changed type"
      assert_no_selector "[data-drift-change='unit_kind_changed']"
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "read a declaration as one row that fits" do
      sign_in_as(@admin.user)
      visit changes_plan_path(@whole)

      assert_selector ROW, count: 1, text: "Checkout was given its own structure: 2 units changed type"
      assert_no_sideways_overflow
    end

    should "read a move into a structure as one row that fits" do
      move_ledger_in
      sign_in_as(@admin.user)
      visit changes_plan_path(@whole)

      assert_selector MOVE, count: 1, text: "Ledger moved into Checkout's structure: 1 unit changed type"
      assert_no_sideways_overflow
    end
  end

  private

  def move_ledger_in
    pod = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@checkout).sole.id }
    call(Operations::OrgGraph::MoveUnit, unit_id: @ledger, parent_id: @checkout, conversion: { @squad => pod })
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person), params:)
    end
  end
end
