# frozen_string_literal: true

require "test_helper"

class Plans::BudgetLinesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
      @line = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2027-12-31", origin: "new", amount: 80_000, currency: "AUD",
                                 period: "year", cost_centre: "Platform").id
    end
  end

  FORM = { starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new", amount: "95,000", currency: "AUD", period: "year",
           head_count: "", position: "", location: "", cost_centre: "Growth" }.freeze

  context "an editor" do
    setup { sign_in @editor.user }

    should "be offered Add a line and Change on a scenario, and neither on Today" do
      get budget_plan_path(@plan_id, scenario: @q1)
      assert_select "#budget-line-add[href=?]", new_budget_line_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-budget-line='#{@line}'] a[href=?]", edit_budget_line_plan_path(@plan_id, budget_line_id: @line, scenario: @q1), text: "Change"

      get budget_plan_path(@plan_id)
      assert_select "#budget-line-add", count: 0
      assert_select "a", text: "Change", count: 0
    end

    should "add a line to the scenario and land back on its budget" do
      get new_budget_line_plan_path(@plan_id, scenario: @q1)
      assert_select "#budget-line-heading", text: "Add a budget line to Q1 hires"

      post create_budget_line_plan_path(@plan_id), params: { scenario_id: @q1, budget_line: FORM }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @q1)
      assert_equal "Budget line added.", flash[:notice]
      added = lines(@q1).find { it[:source] == "plan" }
      assert_equal [ "95000.00", "Growth" ], added.values_at(:amount, :cost_centre)
      assert_empty lines(@plan_id).select { it[:source] == "plan" }
    end

    should "change a line in the scenario, leaving Today's as approved" do
      get edit_budget_line_plan_path(@plan_id, budget_line_id: @line, scenario: @q1)
      assert_select "#budget-line-cost-centre[value=?]", "Platform"

      patch update_budget_line_plan_path(@plan_id, budget_line_id: @line), params: { scenario_id: @q1, budget_line: FORM }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @q1)
      assert_equal "Budget line changed.", flash[:notice]
      assert_equal "Growth", lines(@q1).find { it[:budget_line_id] == @line }[:cost_centre]
      assert_equal "Platform", lines(@plan_id).find { it[:budget_line_id] == @line }[:cost_centre]
    end

    should "show a refused change again with what was typed, and no amount in the flash" do
      patch update_budget_line_plan_path(@plan_id, budget_line_id: @line), params: { scenario_id: @q1, budget_line: FORM.merge(amount: "12,34") }

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /amount must be a number/
      assert_select "#budget-line-amount[value=?]", "12,34"
      assert_select "#budget-line-cost-centre[value=?]", "Growth"
      assert_nil flash[:alert]
    end

    should "cut a line from the scenario" do
      delete cut_budget_line_plan_path(@plan_id, budget_line_id: @line), params: { scenario_id: @q1 }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @q1)
      assert_equal "Budget line cut.", flash[:notice]
      assert_empty lines(@q1)
      assert_equal [ @line ], lines(@plan_id).pluck(:budget_line_id)
    end

    should "be sent back to the tab on Today, which holds the organisation's budget" do
      get new_budget_line_plan_path(@plan_id, scenario: @plan_id)
      assert_redirected_to budget_plan_path(@plan_id, scenario: @plan_id)
      assert_equal Operations::TeamPlanning::BudgetLineWrite::BASELINE, flash[:alert]

      post create_budget_line_plan_path(@plan_id), params: { scenario_id: @plan_id, budget_line: FORM }
      assert_redirected_to budget_plan_path(@plan_id, scenario: @plan_id)
      assert_empty lines(@plan_id).select { it[:source] == "plan" }
    end

    should "get a 404 for a line the scenario doesn't hold" do
      get edit_budget_line_plan_path(@plan_id, budget_line_id: SecureRandom.uuid_v7, scenario: @q1)
      assert_response :not_found
    end

    should "get a 404 for a scenario the plan doesn't hold" do
      get new_budget_line_plan_path(@plan_id, scenario: SecureRandom.uuid_v7)
      assert_response :not_found
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused every write and offered no buttons" do
      get budget_plan_path(@plan_id, scenario: @q1)
      assert_select "#budget-line-add", count: 0
      assert_select "a", text: "Change", count: 0

      post create_budget_line_plan_path(@plan_id), params: { scenario_id: @q1, budget_line: FORM }
      assert_redirected_to root_path
      delete cut_budget_line_plan_path(@plan_id, budget_line_id: @line), params: { scenario_id: @q1 }
      assert_redirected_to root_path
      assert_equal [ @line ], lines(@q1).pluck(:budget_line_id)
    end
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get new_budget_line_plan_path(@plan_id, scenario: @q1)
    assert_response :not_found
  end

  private

  def lines(scenario_id)
    ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::BudgetLines, @editor, plan_id: @plan_id, scenario_id:)[:budget_lines] }
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
