# frozen_string_literal: true

require "test_helper"

class Plans::UndosControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 11, 14, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(@ada.id, provider: "espalia", effective_on: "2026-11-01", employment_status: "employed", level: "3")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1",
                                                                  ends_on: "2027-03-31")[:scenario_id]
      call(Operations::TeamPlanning::SetPlannedLevel, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    end
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "undo their latest change and go back to the tab and scenario it was pressed on" do
      post plan_undos_path(@plan_id), params: { event_id: step[:undo][:event_id], scenario_id: @q1, tab: "changes" }

      assert_redirected_to changes_plan_path(@plan_id, scenario: @q1)
      assert_equal "Change undone.", flash[:notice]
      assert_empty statuses
    end

    should "redo what they undid" do
      event_id = step[:undo][:event_id]
      post plan_undos_path(@plan_id), params: { event_id:, scenario_id: @q1, tab: "map" }
      post plan_redos_path(@plan_id), params: { event_id:, scenario_id: @q1, tab: "budget" }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @q1)
      assert_equal "Change redone.", flash[:notice]
      assert_equal [ "level" ], statuses.pluck(:facet)
    end

    should "clear a change, which Undo then brings back" do
      post plan_clears_path(@plan_id), params: { scenario_id: @q1, subject_id: @ada.id, facet: "level", tab: "changes" }

      assert_redirected_to changes_plan_path(@plan_id, scenario: @q1)
      assert_equal "Change cleared. Undo brings it back.", flash[:notice]
      assert_empty statuses
      assert_equal "clear", step[:undo][:action]
    end

    should "show the operation's own refusal, from a race the offer can't see, and send an unknown tab to the map" do
      refuse = ->(**) { raise Operations::Base::ParameterError, "That change is already undone" }
      Operations::TeamPlanning::UndoChange.stub(:call, refuse) do
        post plan_undos_path(@plan_id), params: { event_id: step[:undo][:event_id], scenario_id: @q1, tab: "https://example.com" }
      end

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Couldn't undo: That change is already undone", flash[:alert]
    end

    should "change nothing when the page named a change that is no longer the one to undo or redo" do
      first = step[:undo][:event_id]
      call_as_editor(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "5")
      post plan_undos_path(@plan_id), params: { event_id: first, scenario_id: @q1, tab: "changes" }

      assert_redirected_to changes_plan_path(@plan_id, scenario: @q1)
      assert_equal Plans::UndoOffer::STALE, flash[:alert]
      assert_nil step[:redo]

      post plan_redos_path(@plan_id), params: { event_id: first, scenario_id: @q1, tab: "changes" }
      assert_equal Plans::UndoOffer::STALE, flash[:alert]
      assert_equal [ "level" ], statuses.pluck(:facet)
    end
  end

  should "refuse a viewer each of the three" do
    sign_in @viewer.user
    event_id = step[:undo][:event_id]
    post plan_undos_path(@plan_id), params: { event_id:, scenario_id: @q1, tab: "changes" }
    assert_redirected_to root_path
    post plan_clears_path(@plan_id), params: { scenario_id: @q1, subject_id: @ada.id, facet: "level", tab: "changes" }
    assert_redirected_to root_path

    assert_equal [ "level" ], statuses.pluck(:facet)
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path # an error response sets no session cookie, so the sign-in must land first
    post plan_redos_path(@plan_id), params: { event_id: step[:undo][:event_id], scenario_id: @q1, tab: "changes" }

    assert_response :not_found
  end

  private

  def step = ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::UndoStep, @editor, plan_id: @plan_id, scenario_id: @q1) }

  def call_as_editor(operation, **params) = ActsAsTenant.with_tenant(@tenant) { call(operation, @editor, **params) }

  def statuses
    ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::Status, @editor, plan_id: @plan_id, scenario_id: @q1)[:statuses] }
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
