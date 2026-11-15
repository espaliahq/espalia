# frozen_string_literal: true

require "test_helper"

class Plans::SettlementsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    @org = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    travel_to Time.utc(2026, 11, 14, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @org.record_person(@ada.id, **ESPALIA, effective_on: "2026-11-01", employment_status: "employed", level: "3")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1",
                                                                  ends_on: "2027-03-31")[:scenario_id]
      @lean = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, parent_id: @q1, relation: "instead",
                                                                    name: "Lean Q1")[:scenario_id]
      call(Operations::TeamPlanning::SetPlannedLevel, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    end
    travel_to(Time.utc(2026, 11, 18, 9)) { ActsAsTenant.with_tenant(@tenant) { @org.change_level(@ada.id, "5", **ESPALIA, effective_on: "2026-11-18") } }
    travel_to Time.utc(2026, 11, 20, 9)
    ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::RebasePlan, @editor, plan_id: @plan_id, base_on: "2026-11-14") }
  end

  def settle(choice, scenario_id: @lean)
    post plan_settlements_path(@plan_id), params: { settlement: { scenario_id:, subject_id: @ada.id, facet: "level", choice: } }
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "keep the plan in the scenario shown, and go back to it" do
      settle("plan")

      assert_redirected_to changes_plan_path(@plan_id, scenario: @lean)
      assert_equal "Kept the plan.", flash[:notice]
      assert_equal "pending", status(@lean)[:status].to_s
      assert_equal "conflicting", status(@q1)[:status].to_s
    end

    should "follow reality in the scenario shown alone" do
      settle("reality")

      assert_equal "Following reality.", flash[:notice]
      assert_not_equal "conflicting", status(@lean)[:status].to_s
      assert_equal "conflicting", status(@q1)[:status].to_s
    end

    should "offer the buttons only on a carried conflict, and send one the update hasn't reached to the next update" do
      get changes_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-planned-change='conflicting'] [data-settle-conflict='level'] button", text: /Keep the plan|Follow reality/, count: 2

      settle("plan", scenario_id: @q1)
      ActsAsTenant.with_tenant(@tenant) { @org.change_level(@ada.id, "6", **ESPALIA, effective_on: "2026-11-20") }
      get changes_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-settle-conflict='live']", text: /settled after the next update to today/
      assert_select "[data-settle-conflict] button", count: 0
    end

    should "say why a settle was refused" do
      settle("plan")
      settle("plan")

      assert_redirected_to changes_plan_path(@plan_id, scenario: @lean)
      assert_match(/\ACouldn't settle the conflict: .*nothing to settle/, flash[:alert])
    end
  end

  should "refuse a viewer" do
    sign_in @viewer.user
    settle("reality")

    assert_redirected_to root_path
    assert_equal "conflicting", status(@lean)[:status].to_s
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path # an error response sets no session cookie, so the sign-in must land first
    settle("reality")

    assert_response :not_found
  end

  private

  def status(scenario_id)
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::Status, @editor, plan_id: @plan_id, scenario_id:)[:statuses].find { it[:subject_id] == @ada.id }
    end
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
