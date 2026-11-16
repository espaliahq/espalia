# frozen_string_literal: true

require "test_helper"

class Plans::StepOutcomesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FRAME = { "Turbo-Frame" => "step-outcome-frame" }.freeze

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(role: :admin, team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @payments = unit("Payments")
      @ada = create(:person, tenant: @tenant, name: "Ada Lovelace")
      org = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      org.record_person(@ada.id, provider: "espalia", effective_on: "2026-12-01", employment_status: "employed", title: "Engineer", level: "5", fte: 1.0)
      org.set_membership(@ada.id, @payments, provider: "espalia", effective_on: "2026-12-01", allocation: 1.0)
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Next year", base_on: "2027-01-01", unit_ids: [ @payments ])[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
    end
    travel_to Time.utc(2027, 4, 2, 9)
  end

  context "a closed step" do
    setup do
      ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::CloseStep, @editor, plan_id: @plan_id, scenario_id: @q1) }
    end

    should "offer a viewer its outcome dialog, whose frame reads unit by unit" do
      sign_in @viewer.user
      get plan_path(@plan_id)
      assert_select "##{Views::Plans::StepOutcomeDialog.id_for(@q1)} turbo-frame[src='#{plan_scenario_outcome_path(@plan_id, @q1)}'][loading=lazy]"
      assert_select "tr[data-scenario-id='#{@q1}'] button[data-modal-target-id='#{Views::Plans::StepOutcomeDialog.id_for(@q1)}']",
                    text: "Planned against actual…"

      get plan_scenario_outcome_path(@plan_id, @q1), headers: FRAME
      assert_response :success
      assert_select "[data-step-outcome-as-of]", text: "As the organisation stood on 31 Mar 2027, as the Org Graph reads today."
      assert_select "tr[data-step-outcome-unit='#{@payments}']" do
        assert_select "th", text: "Payments"
        assert_select "[data-step-outcome=as_planned] dd", text: "Ada Lovelace"
      end
      assert_select "li[data-step-outcome-card='#{@payments}']", text: /Planned 1 · Actual 1/
    end

    should "offer it on the timeline too" do
      sign_in @viewer.user
      get timeline_plan_path(@plan_id)
      assert_select "button[data-modal-target-id='#{Views::Plans::StepOutcomeDialog.id_for(@q1)}']", minimum: 1
      assert_select "##{Views::Plans::StepOutcomeDialog.id_for(@q1)}", count: 1
    end

    should "send a request outside the frame back to the plan" do
      sign_in @viewer.user
      get plan_scenario_outcome_path(@plan_id, @q1)
      assert_redirected_to plan_path(@plan_id)
    end
  end

  should "say why an open step has no outcome, and offer none on the page" do
    sign_in @editor.user
    get plan_path(@plan_id)
    assert_select "##{Views::Plans::StepOutcomeDialog.id_for(@q1)}", count: 0

    get plan_scenario_outcome_path(@plan_id, @q1), headers: FRAME
    assert_select "turbo-frame##{Views::Plans::StepOutcome.frame_id(@q1)}", text: TeamPlanning::StepOutcome::NOT_CLOSED
  end

  should "answer someone outside the plan as if it weren't there" do
    ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::CloseStep, @editor, plan_id: @plan_id, scenario_id: @q1) }
    sign_in @outsider.user
    get plans_path # an error response sets no session cookie, so the sign-in must land first
    get plan_scenario_outcome_path(@plan_id, @q1), headers: FRAME

    assert_response :not_found
  end

  private

  def unit(name)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    level_id = SecureRandom.uuid_v7
    structure.define_taxonomy([ { level_id:, name: "Department" } ], effective_on: "2026-01-01")
    SecureRandom.uuid_v7.tap { structure.create_unit(it, name, level_id:, effective_on: "2026-01-01") }
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
