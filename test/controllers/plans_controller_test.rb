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
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
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
      assert_includes response.body, "Today"
      assert_includes response.body, "Q1 hires"
      assert_includes response.body, "Erin Editor"
      assert_includes response.body, "your organisation&#39;s defaults"
    end

    should "open the map on today, and on a scenario" do
      get map_plan_path(@plan_id)
      assert_response :success
      assert_includes response.body, "Read only."
      assert_not_includes response.body, "with this scenario&#39;s changes"

      get map_plan_path(@plan_id, scenario: @q1)
      assert_response :success
      assert_includes response.body, "with this scenario&#39;s changes"
    end

    should "get a 404 for a scenario that isn't in the plan" do
      get map_plan_path(@plan_id, scenario: SecureRandom.uuid_v7)
      assert_response :not_found
    end

    should "get a 404 for a timeline to a scenario that isn't in the plan" do
      get timeline_plan_path(@plan_id, scenario: SecureRandom.uuid_v7)
      assert_response :not_found
    end

    should "open the changes on today, and on a scenario, each section empty until something changes" do
      get changes_plan_path(@plan_id)
      assert_response :success
      assert_select "[aria-current='page']", text: "Changes"
      assert_includes response.body, "Nothing has changed in the Org Graph since the base."
      assert_select "#changes-planned-heading", text: "Planned in Today"
      assert_includes response.body, "Everything in this scenario still fits."

      get changes_plan_path(@plan_id, scenario: @q1)
      assert_response :success
      assert_select "#changes-planned-heading", text: "Planned in Q1 hires"
    end

    should "get a 404 for changes in a scenario that isn't in the plan" do
      get changes_plan_path(@plan_id, scenario: SecureRandom.uuid_v7)
      assert_response :not_found
    end

    should "open the timeline on the path to the first leaf, its steps shown though nobody is placed yet" do
      get timeline_plan_path(@plan_id)
      assert_response :success
      assert_includes response.body, "No one is placed on this path yet."
      assert_select "[data-timeline-step]", 2
      assert_select "[data-timeline-step='1']", text: /Q1 hires/
    end
  end

  context "someone outside the plan" do
    should "not see it in the index, and get a 404 for its page, map, timeline and changes, even as a tenant admin" do
      [ @outsider, @admin ].each do |account|
        sign_in account.user
        get plans_path
        assert_response :success
        assert_not_includes response.body, "Pay review 2027"

        get plan_path(@plan_id)
        assert_response :not_found
        get map_plan_path(@plan_id)
        assert_response :not_found
        get timeline_plan_path(@plan_id)
        assert_response :not_found
        get changes_plan_path(@plan_id)
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
      plan = ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.order(:created_at).last }
      assert_equal "Reorg 2027", plan.name.reveal
      assert_redirected_to plan_path(plan.id)
    end

    should "see why a plan could not be created, and keep what they typed" do
      post plans_path, params: { plan: { name: "Reorg 2027", base_on: "not a date" } }
      assert_response :unprocessable_content
      assert_select "input#plan_name[value='Reorg 2027']"
      assert_select "input#plan_base_on[value='not a date']"
    end
  end

  context "updating a plan to today" do
    setup { travel_to Time.utc(2026, 11, 20, 9) }

    should "show an editor the preview, then move the base to the day it read" do
      sign_in @editor.user
      get changes_plan_path(@plan_id)
      assert_select "a[href='#{rebase_plan_path(@plan_id)}']", text: "Update to today"

      get rebase_plan_path(@plan_id)
      assert_response :success
      assert_select "[data-update-to-today] input[name='base_on'][value='2026-11-14']"
      assert_includes response.body, "The plan stands on 14 Nov 2026"

      post rebase_plan_path(@plan_id), params: { base_on: "2026-11-14" }
      assert_redirected_to changes_plan_path(@plan_id)
      assert_equal "Updated to today, 20 Nov 2026.", flash[:notice]
      assert_equal "2026-11-20", plan_base_on

      get changes_plan_path(@plan_id)
      assert_select "a[href='#{rebase_plan_path(@plan_id)}']", count: 0
    end

    should "refuse an update since the preview was read, and send back a plan already on today" do
      sign_in @editor.user
      post rebase_plan_path(@plan_id), params: { base_on: "2026-11-01" }
      assert_redirected_to changes_plan_path(@plan_id)
      assert_match(/\ACouldn't update to today: This plan has moved since you looked/, flash[:alert])
      assert_equal "2026-11-14", plan_base_on

      post rebase_plan_path(@plan_id), params: { base_on: "2026-11-14" }
      get rebase_plan_path(@plan_id)
      assert_redirected_to changes_plan_path(@plan_id)
      assert_equal "Can't update to today: This plan already stands on today, 2026-11-20", flash[:alert]
    end

    should "offer a viewer no update and refuse one, and give someone outside the plan a 404" do
      sign_in @viewer.user
      get changes_plan_path(@plan_id)
      assert_select "a[href='#{rebase_plan_path(@plan_id)}']", count: 0
      get rebase_plan_path(@plan_id)
      assert_redirected_to root_path
      post rebase_plan_path(@plan_id), params: { base_on: "2026-11-14" }
      assert_redirected_to root_path
      assert_equal "2026-11-14", plan_base_on

      sign_out @viewer.user
      sign_in @admin.user
      get plans_path
      post rebase_plan_path(@plan_id), params: { base_on: "2026-11-14" }
      assert_response :not_found
    end
  end

  private

  def plan_base_on = ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find(@plan_id).base_on.iso8601 }

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
