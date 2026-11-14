# frozen_string_literal: true

require "test_helper"

class Plans::AssignmentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: level, effective_on: "2026-01-01")
      graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      graph.record_person(@ada.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      graph.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-02", allocation: 1.0)
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
    end
  end

  def move(scenario_id: @q1, **fields)
    patch plan_assignment_path(@plan_id, @ada.id),
          params: { move: { scenario_id:, from_unit_id: @payments, to: @growth, allocation: "60", role: "Lead", **fields } }
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "move a person in the scenario shown and land back on its map" do
      move

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Move saved.", flash[:notice]
      assert_equal [ { unit_id: @growth, allocation: 0.6, role: "Lead" } ], places(@q1)
    end

    should "drop a place on Unassigned, ignoring the allocation the hidden field still holds" do
      move(to: "unassigned")

      assert_empty places(@q1)
    end

    should "place a person in a position the form names as a choice" do
      position = ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
        level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
        call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                            level_id: level.level_id, unit_id: @growth, fte: 1, basis: "new")[:position_id]
      end

      move(to: Views::Plans::MoveDialog.position_choice(position))

      assert_equal "Move saved.", flash[:notice]
      assert_equal [ { unit_id: @growth, allocation: 0.6, role: "Lead" } ], places(@q1)
      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-map-position='#{position}'] [data-map-occupant='#{@ada.id}']"
    end

    should "name each position choice by its level, and number ones that still read alike as the map does" do
      ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
        level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
        2.times do
          call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                              level_id: level.level_id, unit_id: @growth, fte: 1, basis: "new")
        end
      end

      get map_plan_path(@plan_id, scenario: @q1)

      choices = css_select("#move-to option[value^='#{Views::Plans::MoveDialog::POSITION}']")
      assert_equal [ "Growth › New position: Software Engineer (1) · Engineer II", "Growth › New position: Software Engineer (2) · Engineer II" ],
                   choices.map(&:text)
      choices.each_with_index do |choice, index|
        position = choice["value"].delete_prefix(Views::Plans::MoveDialog::POSITION)
        assert_select "[data-map-position='#{position}'] span.font-medium", text: "New position: Software Engineer (#{index + 1})"
        assert_select "[data-map-position='#{position}'] button[aria-label='Move New position: Software Engineer (#{index + 1}) in Growth']"
      end
    end

    should "refuse Today and say why" do
      move(scenario_id: @plan_id)

      assert_redirected_to map_plan_path(@plan_id)
      assert_equal "Couldn't move them: Today can't be edited. Fork a scenario and edit that.", flash[:alert]
      assert_equal [ @payments ], places(@plan_id).pluck(:unit_id)
    end

    should "be offered Move on a scenario's map and not on Today's" do
      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "li[data-map-person='#{@ada.id}'][draggable='true'] button[data-move-from='#{@payments}']", text: "Move…"
      assert_select "form[data-controller='move-form'] strong", text: "Q1 hires"

      get map_plan_path(@plan_id)
      assert_select "button", text: "Move…", count: 0
      assert_select "[draggable]", count: 0
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused a move and offered no handles" do
      move
      assert_redirected_to root_path
      assert_equal [ @payments ], places(@q1).pluck(:unit_id)

      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "button", text: "Move…", count: 0
      assert_select "[draggable]", count: 0
    end
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path
    move
    assert_response :not_found
  end

  private

  def places(scenario_id)
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::ScenarioMap, @editor, plan_id: @plan_id, scenario_id:)[:people]
        .find { it[:id] == @ada.id }[:memberships].map { it.slice(:unit_id, :allocation, :role).compact }
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
