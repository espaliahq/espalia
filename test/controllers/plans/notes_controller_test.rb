# frozen_string_literal: true

require "test_helper"

class Plans::NotesControllerTest < ActionDispatch::IntegrationTest
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
      call(Operations::TeamPlanning::SetPlannedLevel, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4",
                                                               note: "Ready since the launch")
    end
    @change_id = status[:change_id]
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "rewrite a note and go back to the Changes tab" do
      patch plan_note_path(@plan_id, @change_id), params: { note: { scenario_id: @q1, text: "Ready, and asked for it" } },
                                                  headers: { "HTTP_REFERER" => changes_plan_url(@plan_id, scenario: @q1) }

      assert_redirected_to changes_plan_url(@plan_id, scenario: @q1)
      assert_equal "Note saved.", flash[:notice]
      assert_equal({ value: "Ready, and asked for it" }, status[:note])
    end

    should "clear a note with a blank" do
      patch plan_note_path(@plan_id, @change_id), params: { note: { scenario_id: @q1, text: "" } }

      assert_equal "Note cleared.", flash[:notice]
      assert_not status.key?(:note)
    end

    should "say why a note was refused" do
      patch plan_note_path(@plan_id, @change_id), params: { note: { scenario_id: @q1, text: "x" * (TeamPlanning::PlanAggregate::NOTE_LIMIT + 1) } }

      assert_match(/\ACouldn't save the note: /, flash[:alert])
      assert_equal({ value: "Ready since the launch" }, status[:note])
    end
  end

  should "refuse a viewer" do
    sign_in @viewer.user
    patch plan_note_path(@plan_id, @change_id), params: { note: { scenario_id: @q1, text: "Mine" } }

    assert_redirected_to root_path
    assert_equal({ value: "Ready since the launch" }, status[:note])
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path # an error response sets no session cookie, so the sign-in must land first
    patch plan_note_path(@plan_id, @change_id), params: { note: { scenario_id: @q1, text: "Mine" } }

    assert_response :not_found
  end

  private

  def status
    ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::Status, @editor, plan_id: @plan_id, scenario_id: @q1)[:statuses].sole }
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
