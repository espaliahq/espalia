# frozen_string_literal: true

require "test_helper"

class Plans::ChangeUndosControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia", effective_on: "2026-11-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @engineering, @sales = Array.new(2) { SecureRandom.uuid_v7 }
    travel_to Time.utc(2026, 11, 10, 9)
    ActsAsTenant.with_tenant(@tenant) do
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")
      structure.create_unit(@sales, "Sales", level_id: departments, effective_on: "2026-01-01")
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @dee = create(:person, tenant: @tenant, name: "Dee Quill")
      people.record_person(@dee.id, **ESPALIA, employment_status: "employed", level: "3")
      people.set_membership(@dee.id, @sales, **ESPALIA, allocation: 1.0)
    end
    travel_to Time.utc(2026, 11, 14, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Engineering next year", base_on: "2026-11-14", unit_ids: [ @engineering ])[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
      @lean = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, parent_id: @q1, relation: "instead", name: "Lean Q1")[:scenario_id]
      call(Operations::TeamPlanning::SetAssignment, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @dee.id,
                                                             placements: [ { unit_id: @engineering, allocation: 1 } ])
      call(Operations::TeamPlanning::SetPlannedLevel, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @dee.id, level: "4")
      call(Operations::TeamPlanning::ClearChange, @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @dee.id, facet: "assignment")
    end
  end

  def undo(change_id: level_change[:change_id])
    post plan_change_undos_path(@plan_id), params: { scenario_id: @q1, event_id: change_id, tab: "changes" }
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "see Clear and Undo on a change about someone the plan no longer covers, in the scenario that made it" do
      get changes_plan_path(@plan_id, scenario: @q1)

      assert_select "[data-planned-change='outside']", text: /Someone this plan no longer covers/
      assert_select "[data-planned-change='outside'] [data-clear-change='level']", count: 1
      assert_select "[data-planned-change='outside'] [data-undo-change='level'] button", text: "Undo", count: 1
      assert_no_match "Dee Quill", response.body
    end

    should "see neither in a scenario that only inherits it" do
      get changes_plan_path(@plan_id, scenario: @lean)

      assert_select "[data-planned-change='outside']", text: /Someone this plan no longer covers/
      assert_select "[data-planned-change='outside'] [data-clear-change], [data-planned-change='outside'] [data-undo-change]", count: 0
    end

    should "clear it through the plan page's Clear" do
      post plan_clears_path(@plan_id), params: { scenario_id: @q1, subject_id: @dee.id, facet: "level", tab: "changes" }

      assert_redirected_to changes_plan_path(@plan_id, scenario: @q1)
      assert_nil level_change
    end

    should "undo it, and go back to the tab" do
      undo

      assert_redirected_to changes_plan_path(@plan_id, scenario: @q1)
      assert_equal "Change undone.", flash[:notice]
      assert_nil level_change
    end

    should "say why an undo was refused" do
      change_id = level_change[:change_id]
      undo(change_id:)
      undo(change_id:)

      assert_redirected_to changes_plan_path(@plan_id, scenario: @q1)
      assert_match(/\ACouldn't undo: /, flash[:alert])
    end
  end

  should "refuse a viewer" do
    sign_in @viewer.user
    undo

    assert_redirected_to root_path
    assert level_change
  end

  private

  def level_change
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::Status, @editor, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:subject_id] == @dee.id && it[:facet] == "level" }
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
