# frozen_string_literal: true

require "test_helper"

class Plans::ScenarioDatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1 hires", ends_on: "2027-03-31")[:scenario_id]
      @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2 settle",
                                                         ends_on: "2027-06-30")[:scenario_id]
    end
  end

  def periods
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].to_h { [ it[:scenario_id], it.values_at(:starts_on, :ends_on) ] }
    end
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "show a later step's start as set by the step before it, with no field to change it" do
      get dates_plan_path(@plan_id, scenario_id: @q2)

      assert_response :success
      assert_select "h3", text: "Dates for Q2 settle"
      assert_select "input[name='starts_on']", count: 0
      assert_select "[data-dates-start='#{@q2}']", text: /1 Apr 2027, the day after Q1 hires ends/
      assert_select "[data-dates-start='#{@q2}'] a[href='#{dates_plan_path(@plan_id, scenario_id: @q1)}']", text: "Q1 hires"
      assert_select "input[name='ends_on'][value='2027-06-30']"
    end

    should "preview what a new end moves, without moving anything" do
      get dates_plan_path(@plan_id, scenario_id: @q1, ends_on: "2027-04-30")

      assert_select "[data-dates-move='#{@q1}']", text: "Q1 hires: 14 Nov 2026 to 31 Mar 2027, now 14 Nov 2026 to 30 Apr 2027."
      assert_select "[data-dates-move='#{@q2}']", text: "Q2 settle: Apr to Jun 2027, now May to Jun 2027."
      assert_select "form[method='post'] input[name='ends_on'][value='2027-04-30']"
      assert_select "form[method='post'] input[name='starts_on'][value='2026-11-14']"
      assert_equal [ "2026-11-14", "2027-03-31" ], periods[@q1]
    end

    should "save the dates and go back to the map with the step open, when the editor came from there" do
      get dates_plan_path(@plan_id, scenario_id: @q1, from: "map")
      assert_select "a[href='#{map_plan_path(@plan_id, scenario: @q1)}']", text: "Cancel"

      post dates_plan_path(@plan_id, scenario_id: @q1), params: { ends_on: "2027-04-30", from: "map" }

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Saved the dates of Q1 hires.", flash[:notice]
      assert_equal [ "2027-05-01", "2027-06-30" ], periods[@q2]
    end

    should "let a first step start after the base, and go back to the scenarios" do
      post dates_plan_path(@plan_id, scenario_id: @q1), params: { starts_on: "2026-12-01", ends_on: "2027-03-31" }

      assert_redirected_to plan_path(@plan_id)
      assert_equal [ "2026-12-01", "2027-03-31" ], periods[@q1]
    end

    should "say why dates were refused and keep them on the page" do
      post dates_plan_path(@plan_id, scenario_id: @q1), params: { starts_on: "2026-11-01", ends_on: "2027-03-31" }

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /Couldn't use those dates/
      assert_select "input[name='starts_on'][value='2026-11-01']"
      assert_equal [ "2026-11-14", "2027-03-31" ], periods[@q1]
    end

    should "offer Dates… for a step on the scenarios table and the map" do
      get plan_path(@plan_id)
      assert_select "a[href='#{dates_plan_path(@plan_id, scenario_id: @q1)}']", text: "Dates…"

      get map_plan_path(@plan_id, scenario: @q2)
      assert_select "a[href='#{dates_plan_path(@plan_id, scenario_id: @q2, from: 'map')}']", text: "Dates…"
    end

    should "go back to the map of a split's rest when its Dates… opened the agreed part" do
      rest = @q1
      agreed = ActsAsTenant.with_tenant(@tenant) do
        leaving = [ "Ada Quill", "Bo Brook" ].map do |name|
          person = create(:person, tenant: @tenant, name:)
          OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                  .record_person(person.id, provider: "espalia", effective_on: "2026-01-02", employment_status: "employed")
          call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: rest, person_id: person.id)
          call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: rest)[:entries].last[:event_id]
        end.first
        call(Operations::TeamPlanning::SplitScenario, plan_id: @plan_id, scenario_id: rest, event_ids: [ leaving ], name: "Agreed")[:agreed_id]
      end
      get map_plan_path(@plan_id, scenario: rest)
      dates = dates_plan_path(@plan_id, scenario_id: agreed, from: "map", map_scenario: rest)
      assert_select "a[href='#{dates}']", text: "Dates…"

      get dates
      assert_select "a[href='#{map_plan_path(@plan_id, scenario: rest)}']", text: "Cancel"
      assert_select "input[name='map_scenario'][value='#{rest}']"

      post dates_plan_path(@plan_id, scenario_id: agreed), params: { ends_on: "2027-04-30", from: "map", map_scenario: rest }
      assert_redirected_to map_plan_path(@plan_id, scenario: rest)
    end
  end

  should "refuse a viewer, and offer them no Dates…" do
    sign_in @viewer.user
    get dates_plan_path(@plan_id, scenario_id: @q1)
    assert_redirected_to root_path

    post dates_plan_path(@plan_id, scenario_id: @q1), params: { ends_on: "2027-04-30" }
    assert_redirected_to root_path
    assert_equal [ "2026-11-14", "2027-03-31" ], periods[@q1]

    get plan_path(@plan_id)
    assert_select "a", text: "Dates…", count: 0
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get dates_plan_path(@plan_id, scenario_id: @q1)
    assert_response :not_found
  end

  private

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, **params)
    context = AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person)
    operation.call(context:, params:)
  end
end
