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
      @role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 2, title: "Engineer II", code: "E2")
      @senior = create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 3, title: "Senior Engineer", code: "E3")
      @position = call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: @role.role_id,
                                                                     level_id: @level.level_id, unit_id: @payments, fte: 1, basis: "new",
                                                                     cost_centre: "Platform")[:position_id]
    end
  end

  def move(scenario_id: @q1, to_unit_id: @growth)
    patch move_plan_position_path(@plan_id, @position), params: { move: { scenario_id:, to_unit_id: } }
  end

  def open_position(as: :html, **fields)
    post plan_positions_path(@plan_id), as:, params: { position: { scenario_id: @q1, unit_id: @growth, level_id: @senior.level_id,
                                                                   fte: "0.5", basis: "backfill", cost_centre: "" }.merge(fields) }
  end

  ORIGINAL = { basis: "new", cost_centre: "Platform", fte: "1.0" }.freeze

  def edit_position(scenario_id: @q1, original: ORIGINAL, as: :html, **fields)
    patch plan_position_path(@plan_id, @position), as:, params: { position: { scenario_id:, **fields }, original: }
  end

  def close_position(scenario_id: @q1)
    delete plan_position_path(@plan_id, @position), params: { scenario_id: }
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

    should "be offered Edit, Move and Close on a scenario's positions, and Open on each unit" do
      get map_plan_path(@plan_id, scenario: @q1)
      row = "[data-map-position='#{@position}'][draggable='true']"
      assert_select "#{row} button[aria-haspopup=menu][data-menu=position][data-menu-unit='#{@payments}']" \
                    "[data-menu-level='#{@level.level_id}'][data-menu-cost-centre='Platform']"
      assert_select "template[data-delegated-menu-kind=position]", count: 1
      assert_select "template[data-delegated-menu-kind=position] [role=menuitem]", text: /Edit…|Move…|Close…/, count: 3
      assert_select "template [data-modal-target-id='move-position-modal'][data-move-action='{move-path}'][data-move-from='{unit}']"
      assert_select "button[aria-label='Open a position in Growth'][data-position-unit-id='#{@growth}']"
      assert_select "#move-position-modal form strong", text: "Q1 hires"
      assert_select "#edit-position-modal optgroup[label='Software Engineer'] option[value='#{@senior.level_id}']",
                    text: "Software Engineer, E3 Senior Engineer"
    end

    should "open a position in a unit" do
      open_position

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Position opened.", flash[:notice]
      opened = positions.find { it[:unit_id] == @growth }
      assert_equal [ @role.role_id, @senior.level_id, 0.5, "backfill", nil ], opened.values_at(:role_id, :level_id, :fte, :basis, :cost_centre)
    end

    should "save only the fields the dialog changed" do
      ActsAsTenant.with_tenant(@tenant) do
        call(Operations::TeamPlanning::EditPosition, @editor, plan_id: @plan_id, scenario_id: @q1, position_id: @position, fte: 0.8)
      end
      edit_position(fte: "1.0", basis: "new", cost_centre: "Ledger", level_id: @senior.level_id, unit_id: @payments)

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Position saved.", flash[:notice]
      assert_equal [ @senior.level_id, 0.8, "Ledger" ], position.values_at(:level_id, :fte, :cost_centre)
    end

    should "say when nothing changed" do
      edit_position(fte: "1.0", basis: "new", cost_centre: "Platform")
      assert_equal "Nothing changed.", flash[:notice]
    end

    should "keep what was typed in the dialog when a save is refused" do
      edit_position(as: :turbo_stream, fte: "1.5", cost_centre: "Ledger")

      assert_response :unprocessable_content
      assert_select "turbo-stream[action=replace][target=edit-position-form] template" do
        assert_select "[role=alert]", text: /FTE/
        assert_select "input[name='position[cost_centre]'][value=Ledger]"
        assert_select "input[name='position[fte]'][value='1.5']"
        assert_select "input[name='original[cost_centre]'][value=Platform]"
      end
      assert_equal "Platform", position[:cost_centre]
    end

    should "refuse a position with no role and level" do
      open_position(as: :turbo_stream, level_id: "")

      assert_response :unprocessable_content
      assert_select "turbo-stream[target=open-position-form] template [role=alert]", text: /Choose a role and level/
    end

    should "close a position" do
      close_position

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Position closed.", flash[:notice]
      assert_nil position
    end

    should "refuse to change Today, whichever way" do
      edit_position(scenario_id: @plan_id, cost_centre: "Ledger")
      assert_equal "Couldn't save the position: #{Plans::PositionsController::TODAY}", flash[:alert]
      open_position(scenario_id: @plan_id)
      assert_equal "Couldn't save the position: #{Plans::PositionsController::TODAY}", flash[:alert]
      close_position(scenario_id: @plan_id)
      assert_equal "Couldn't close the position: #{Plans::PositionsController::TODAY}", flash[:alert]
      assert_equal "Platform", position[:cost_centre]
    end

    should "be refused on an archived plan" do
      ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::ArchivePlan, @editor, plan_id: @plan_id) }
      edit_position(cost_centre: "Ledger")
      assert_equal "Couldn't save the position: This plan is archived: restore it to change it", flash[:alert]
      close_position
      assert_equal "Couldn't close the position: This plan is archived: restore it to change it", flash[:alert]
      assert_equal "Platform", position[:cost_centre]
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused a move, an open, an edit and a close, and offered no handles" do
      move
      assert_redirected_to root_path
      assert_equal @payments, unit_of_position
      [ -> { open_position }, -> { edit_position(cost_centre: "Ledger") }, -> { close_position } ].each do |request|
        request.call
        assert_redirected_to root_path
      end
      assert_equal "Platform", position[:cost_centre]
      assert_equal 1, positions.size

      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "button", text: "Move…", count: 0
      assert_select "button", text: "Open a position", count: 0
      assert_select "#edit-position-modal", count: 0
      assert_select "[draggable]", count: 0
    end
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path
    move
    assert_response :not_found
    edit_position(cost_centre: "Ledger")
    assert_response :not_found
    close_position
    assert_response :not_found
  end

  private

  def positions
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::ScenarioMap, @editor, plan_id: @plan_id, scenario_id: @q1)[:positions]
    end
  end

  def position = positions.find { it[:position_id] == @position }

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
