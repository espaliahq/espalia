# frozen_string_literal: true

require "test_helper"

class Plans::ChangeMovesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(@ada.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1 hires", ends_on: "2027-03-31")[:scenario_id]
      @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2 settle",
                                                         ends_on: "2027-06-30")[:scenario_id]
      call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id)
    end
  end

  def shift(direction: "later", return_to: nil)
    post plan_change_moves_path(@plan_id), params: { move: { scenario_id: @q1, subject_id: @ada.id, facet: "departure", direction: }, return_to: }.compact
  end

  def leaving_in = ActsAsTenant.with_tenant(@tenant) { TeamPlanningOverride.where(facet: "departure").pluck(:scenario_id) }

  context "an editor" do
    setup { sign_in @editor.user }

    should "move a departure a step later and say where it went, back on the timeline step it came from" do
      back = timeline_plan_path(@plan_id, scenario: @q2, step: 1)
      shift(return_to: back)

      assert_redirected_to back
      assert_equal "Moved to Q2 settle.", flash[:notice]
      assert_equal [ @q2 ], leaving_in
    end

    should "say why a move was refused, and ignore a return_to off this plan's timeline" do
      shift(direction: "earlier", return_to: "https://example.com/planning")

      assert_redirected_to timeline_plan_path(@plan_id)
      assert_match "Couldn't move it:", flash[:alert]
      assert_match "baseline", flash[:alert]
      assert_equal [ @q1 ], leaving_in
    end

    should "offer When… on the bar where the departure shows, and none for a change Today holds" do
      get timeline_plan_path(@plan_id, scenario: @q2)

      assert_select "button[aria-label='Change when, for Ada Quill']", text: "When…"
      assert_select "a[data-turbo-method='post']", text: "Leave in Q2 settle instead"
      assert_select "a", text: /Leave in Today/, count: 0
    end
  end

  should "refuse a viewer and offer them no When…" do
    sign_in @viewer.user
    shift
    assert_redirected_to root_path
    assert_equal [ @q1 ], leaving_in

    get timeline_plan_path(@plan_id, scenario: @q2)
    assert_select "button", text: "When…", count: 0
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    shift
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
