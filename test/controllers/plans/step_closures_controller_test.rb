# frozen_string_literal: true

require "test_helper"

class Plans::StepClosuresControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2027, 4, 2, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Next year", base_on: "2027-01-01")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = fork(@plan_id, "Q1", "2027-03-31")
      @lean = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, parent_id: @q1, relation: "instead", name: "Lean Q1")[:scenario_id]
      @q2 = fork(@q1, "Q2", "2027-06-30")
    end
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "see Q1 ready to close, with a dialog that says what closing does" do
      get plan_path(@plan_id)

      assert_select "tr[data-scenario-id='#{@q1}'] [data-step-state=ready_to_close]", minimum: 1
      assert_select "tr[data-scenario-id='#{@q2}'] [data-step-state=open]", minimum: 1
      assert_select "##{Views::Plans::StepClosureDialog.id_for(@q1)}" do
        assert_select "p", text: /start from the organisation as the Org Graph holds it on 1 Apr 2027/
        assert_select "[data-not-taken]", text: "Lean Q1 will read Not taken."
        assert_select "button[type=submit]", text: "Close step"
      end
      assert_select "##{Views::Plans::StepClosureDialog.id_for(@q2)}", count: 0
    end

    should "close Q1, mark Lean Q1 not taken, and offer Q1 back to reopen" do
      post plan_scenario_closure_path(@plan_id, @q1)

      assert_redirected_to plan_path(@plan_id)
      assert_match(/\AClosed Q1\./, flash[:notice])
      get plan_path(@plan_id)
      assert_select "tr[data-scenario-id='#{@q1}'] [data-step-state=closed]", text: /on 2 Apr by Erin Editor/
      assert_select "tr[data-scenario-id='#{@lean}'] [data-step-state=not_taken]", minimum: 1
      assert_select "##{Views::Plans::StepClosureDialog.id_for(@q1)} button[type=submit]", text: "Reopen step"
      assert_select "##{Views::Plans::RemoveScenarioDialog.id_for(@lean)}", count: 0
      assert_select "tr[data-scenario-id='#{@q1}'] a", text: "Dates…", count: 0
    end

    should "reopen Q1 and land back on the timeline it was pressed on" do
      post plan_scenario_closure_path(@plan_id, @q1)
      timeline = timeline_plan_path(@plan_id, scenario: @q2)
      delete plan_scenario_closure_path(@plan_id, @q1), params: { return_to: timeline }

      assert_redirected_to timeline
      assert_equal "Reopened Q1.", flash[:notice]
      assert_equal "ready_to_close", state(@q1)
    end

    should "show the operation's own refusal, and never follow a return_to off the plan" do
      post plan_scenario_closure_path(@plan_id, @q2), params: { return_to: "https://example.com/" }

      assert_redirected_to plan_path(@plan_id)
      assert_equal "Couldn't close Q2: This step ends on 2027-06-30: it can be closed from the day after", flash[:alert]
    end
  end

  should "refuse a viewer, who sees the states but no Close" do
    sign_in @viewer.user
    get plan_path(@plan_id)
    assert_select "[data-step-state=ready_to_close]", minimum: 1
    assert_select "##{Views::Plans::StepClosureDialog.id_for(@q1)}", count: 0

    post plan_scenario_closure_path(@plan_id, @q1)
    assert_redirected_to root_path
    assert_equal "ready_to_close", state(@q1)
  end

  should "answer someone outside the plan as if it weren't there" do
    sign_in @outsider.user
    get plans_path # an error response sets no session cookie, so the sign-in must land first
    post plan_scenario_closure_path(@plan_id, @q1)

    assert_response :not_found
  end

  private

  def fork(parent_id, name, ends_on)
    call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, parent_id:, relation: "then", name:, ends_on:)[:scenario_id]
  end

  def state(scenario_id)
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::Scenarios, @editor, plan_id: @plan_id)[:scenarios].find { it[:scenario_id] == scenario_id }[:state]
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
