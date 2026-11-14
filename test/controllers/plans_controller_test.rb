# frozen_string_literal: true

require "test_helper"

class PlansControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(name: "Olly Outsider")
      @admin = account(role: :admin, name: "Ada Admin")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires", ends_on: "2027-03-31")
    end
  end

  context "a plan's member" do
    setup { sign_in @viewer.user }

    should "see the plan in the index and open its page" do
      get plans_path
      assert_response :success
      assert_includes response.body, "Pay review 2027"
      assert_not_includes response.body, "New plan"

      get plan_path(@plan_id)
      assert_response :success
      assert_includes response.body, "Private to 2 members"
      assert_includes response.body, "Baseline"
      assert_includes response.body, "Q1 hires"
      assert_includes response.body, "Erin Editor"
      assert_includes response.body, "your organisation&#39;s defaults"
    end
  end

  context "someone outside the plan" do
    should "not see it in the index, and get a 404 for its page, even as a tenant admin" do
      [ @outsider, @admin ].each do |account|
        sign_in account.user
        get plans_path
        assert_response :success
        assert_not_includes response.body, "Pay review 2027"

        get plan_path(@plan_id)
        assert_response :not_found
        sign_out account.user
      end
    end

    should "not be offered Planning in the nav unless they may start a plan" do
      sign_in @outsider.user
      get root_path
      assert_select "a[href='/planning']", count: 0

      sign_out @outsider.user
      sign_in @admin.user
      get root_path
      assert_select "a[href='/planning']"
    end

    should "be refused a new plan without the planner role" do
      sign_in @outsider.user
      assert_no_difference -> { TeamPlanningPlan.count } do
        post plans_path, params: { plan: { name: "Mine", base_on: "2026-11-14" } }
      end
      assert_redirected_to root_path
    end
  end

  context "a planner" do
    setup { sign_in @editor.user }

    should "start a plan and land on it" do
      post plans_path, params: { plan: { name: "Reorg 2027", base_on: "2026-11-01" } }
      plan = ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find_by!(name: "Reorg 2027") }
      assert_redirected_to plan_path(plan.id)
    end

    should "see why a plan could not be created" do
      post plans_path, params: { plan: { name: "", base_on: "2026-11-01" } }
      assert_response :unprocessable_content
    end
  end

  private

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
