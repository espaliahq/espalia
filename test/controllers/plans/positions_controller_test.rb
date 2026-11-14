# frozen_string_literal: true

require "test_helper"

class Plans::PositionsControllerTest < ActionDispatch::IntegrationTest
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
      role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
      @position = call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                                     level_id: level.level_id, unit_id: @payments, fte: 1, basis: "new")[:position_id]
    end
  end

  def move(scenario_id: @q1, to_unit_id: @growth)
    patch plan_position_path(@plan_id, @position), params: { move: { scenario_id:, to_unit_id: } }
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "move the position in the scenario shown and land back on its map" do
      move

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Position moved.", flash[:notice]
      assert_equal @growth, unit_of_position
    end

    should "refuse Today and say why" do
      move(scenario_id: @plan_id)

      assert_equal "Couldn't move the position: Today can't be edited. Fork a scenario and edit that.", flash[:alert]
      assert_equal @payments, unit_of_position
    end

    should "be offered Move on a scenario's positions, naming the scenario" do
      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-map-position='#{@position}'][draggable='true'] button[data-move-from='#{@payments}']", text: "Move…"
      assert_select "#move-position-modal form strong", text: "Q1 hires"
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused a move and offered no handles" do
      move
      assert_redirected_to root_path
      assert_equal @payments, unit_of_position

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

  def unit_of_position
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::ScenarioMap, @editor, plan_id: @plan_id, scenario_id: @q1)[:positions]
        .find { it[:position_id] == @position }[:unit_id]
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
