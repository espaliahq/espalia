# frozen_string_literal: true

require "test_helper"

class Tenant::BudgetLinesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @planner_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person = create(:person, tenant: @tenant, name: "Ada Admin"))
      create(:tenant_user, tenant: @tenant, user: @planner_user, role: :member, team_planner: true, org_graph_editor: true)
      @role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, code: "E2", title: "Engineer II")
    end
  end

  def line_params(overrides = {})
    { budget_line: { starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new", approved_on: "2026-10-01",
                     amount: "120,000", currency: "aud", period: "year", head_count: "2",
                     position: "level:#{@level.level_id}", location: "Fixtureland", cost_centre: "R&D" }.merge(overrides) }
  end

  def stored_line(**attrs)
    ActsAsTenant.with_tenant(@tenant) do
      add_planning_input!(:budget_lines, starts_on: "2027-01-01", ends_on: "2027-06-30", origin: "replacement",
                         amount: 9000, currency: "NZD", period: "month", **attrs)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show an empty page with the role and level picker" do
      get tenant_budget_lines_path

      assert_response :success
      assert_includes response.body, "No budget lines yet"
      assert_select "#budget-line-position optgroup[label='Software Engineer'] option", text: "E2 Engineer II"
      assert_select "#budget-line-position option[value='role:#{@role.role_id}']", text: "Any Software Engineer level"
    end

    should "add a line, reading the separators a person types" do
      post tenant_budget_lines_path, params: line_params

      assert_redirected_to tenant_budget_lines_path
      line = ActsAsTenant.with_tenant(@tenant) { BudgetLine.sole }
      assert_equal [ "AUD", BigDecimal("120000"), @level.level_id, @admin_person.id ], [ line.currency, line.amount, line.level_id, line.updated_by_person_id ]

      follow_redirect!
      assert_includes response.body, "Budget line added for Software Engineer, E2 Engineer II."
      assert_includes response.body, "AUD 120,000 a year · Head count 2"
      assert_includes response.body, "New position, approved 1 Oct 2026 · 1 Jan 2027 to 31 Dec 2027 · Fixtureland · Cost centre R&amp;D"
    end

    should "add a head count for any role with no amount, which reads as no amount" do
      post tenant_budget_lines_path, params: line_params(amount: "", currency: "", position: "", head_count: "1")
      follow_redirect!

      assert_includes response.body, "Budget line added for any role."
      assert_includes response.body, "No amount · Head count 1"
      assert_nil ActsAsTenant.with_tenant(@tenant) { BudgetLine.sole.amount }
    end

    should "show a refused line again with what was typed" do
      post tenant_budget_lines_path, params: line_params(ends_on: "2026-12-31")

      assert_response :unprocessable_content
      assert_includes response.body, "The budget line could not be added: A budget line can&#39;t end before it starts."
      assert_select "#budget-line-amount[value='120000']"
      assert_select "#budget-line-position option[selected][value='level:#{@level.level_id}']"
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { BudgetLine.count }
    end

    should "ask for an amount or a head count when a line has neither" do
      post tenant_budget_lines_path, params: line_params(amount: "", currency: "", head_count: "")

      assert_response :unprocessable_content
      assert_includes response.body, "The budget line could not be added: A budget line needs an amount, a head count or both."
    end

    should "change a line, every field as it reads afterwards" do
      line = stored_line(cost_centre: "Ops")

      get edit_tenant_budget_line_path(line)
      assert_response :success
      assert_select "#budget-line-amount[value='9000.00']"

      patch tenant_budget_line_path(line), params: line_params(position: "role:#{@role.role_id}", cost_centre: "")

      assert_redirected_to tenant_budget_lines_path
      line.reload
      assert_equal [ "AUD", "year", @role.role_id, nil, "" ], [ line.currency, line.period, line.role_id, line.level_id, line.cost_centre ]
    end

    should "drop an approval date left on screen when the origin is no longer a new position" do
      line = stored_line(origin: "new", approved_on: "2026-10-01")

      patch tenant_budget_line_path(line), params: line_params(origin: "existing")

      assert_redirected_to tenant_budget_lines_path
      assert_equal [ "existing", nil ], [ line.reload.origin, line.approved_on ]
    end

    should "offer a level that has left the framework on its line's form, and keep it" do
      line = stored_line(level_id: SecureRandom.uuid_v7, role_id: @role.role_id, role_name: "Software Engineer", level_name: "E9 Gone")

      get edit_tenant_budget_line_path(line)
      assert_select "#budget-line-position option[selected][value='level:#{line.level_id}']",
                    text: "Software Engineer, E9 Gone (no longer in the framework)"

      patch tenant_budget_line_path(line), params: line_params(position: "level:#{line.level_id}", head_count: "3")
      assert_redirected_to tenant_budget_lines_path
      assert_equal [ "E9 Gone", BigDecimal(3) ], [ line.reload.level_name, line.head_count ]
    end

    should "show a refused change again with what was typed" do
      line = stored_line

      patch tenant_budget_line_path(line), params: line_params(currency: "DOLLARS")

      assert_response :unprocessable_content
      assert_select "#budget-line-currency[value='DOLLARS']"
      assert_equal "NZD", line.reload.currency
    end

    should "remove a line" do
      delete tenant_budget_line_path(stored_line)

      assert_redirected_to tenant_budget_lines_path
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { BudgetLine.count }
    end

    should "answer 404 for a line the tenant doesn't hold" do
      get edit_tenant_budget_line_path(SecureRandom.uuid_v7)

      assert_response :not_found
    end
  end

  context "as a planner who also edits the Org Graph" do
    setup { sign_in @planner_user }

    should "refuse every budget action, showing no line" do
      line = stored_line

      get tenant_budget_lines_path
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      post tenant_budget_lines_path, params: line_params
      get edit_tenant_budget_line_path(line)
      assert_redirected_to root_path
      assert_no_match(/9,000|NZD/, response.body)
      patch tenant_budget_line_path(line), params: line_params
      delete tenant_budget_line_path(line)

      assert_equal [ 1, "NZD" ], ActsAsTenant.with_tenant(@tenant) { [ BudgetLine.count, BudgetLine.sole.currency ] }
    end
  end
end
