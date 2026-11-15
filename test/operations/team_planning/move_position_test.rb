# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::MovePositionTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @cy = create(:person, tenant: @tenant, name: "Cy Loner")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: level, effective_on: "2026-01-01")
      handler.record_person(@bo.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      handler.set_membership(@bo.id, @payments, **ESPALIA, effective_on: "2026-01-02", allocation: 1)
      handler.record_person(@cy.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      handler.change_manager(@cy.id, @bo.id, **ESPALIA, effective_on: "2026-01-02")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    @position = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                            level_id: @e2.level_id, unit_id: @payments, fte: 0.5, basis: "backfill")[:position_id]
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @q1, person_id: @cy.id,
                                                  placements: [ { position_id: @position, allocation: 0.5 } ])
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def move(as: @editor, scenario_id: @q1, **params)
    call(Operations::TeamPlanning::MovePosition, as:, plan_id: @plan_id, scenario_id:, position_id: @position, **params)
  end

  def map = call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id: @q1)

  def refusal(**params) = assert_raises(Operations::Base::ParameterError) { move(**params) }.message

  should "keep the position's own cost centre" do
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q1, position_id: @position, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id: @payments, fte: 0.5, basis: "backfill", cost_centre: "Platform")
    move(to_unit_id: @growth)

    assert_equal "Platform", map[:positions].find { it[:position_id] == @position }[:cost_centre]
  end

  should "move the position and keep its role, level, FTE and basis" do
    move(to_unit_id: @growth)

    position = map[:positions].find { it[:position_id] == @position }
    assert_equal [ @engineer.role_id, @e2.level_id, @growth, 0.5, "backfill" ],
                 position.values_at(:role_id, :level_id, :unit_id, :fte, :basis).tap { it[3] = it[3].to_f }
  end

  should "take the people in it along and leave their reporting lines alone" do
    move(to_unit_id: @growth)

    cy = map[:people].find { it[:id] == @cy.id }
    assert_equal [ @growth ], cy[:memberships].pluck(:unit_id)
    assert_equal @bo.id, cy[:manager_id]
  end

  should "refuse Today, a viewer, a position the scenario lacks and a unit it lacks" do
    assert_match "Today can't be edited", refusal(scenario_id: @plan_id, to_unit_id: @growth)
    assert_equal "No such plan", refusal(as: @viewer, to_unit_id: @growth)
    assert_equal "This scenario has no such position",
                 assert_raises(Operations::Base::ParameterError) {
                   call(Operations::TeamPlanning::MovePosition, plan_id: @plan_id, scenario_id: @q1, position_id: SecureRandom.uuid_v7, to_unit_id: @growth)
                 }.message
    assert_equal "This scenario has no such unit", refusal(to_unit_id: SecureRandom.uuid_v7)
    assert_equal "The position is already in that unit", refusal(to_unit_id: @payments)
    assert_equal @payments, map[:positions].find { it[:position_id] == @position }[:unit_id]
  end

  should "refuse a position whose unit has been retired" do
    call(Operations::TeamPlanning::RetireUnit, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments)

    assert_equal "This position is in no unit and can't be moved", refusal(to_unit_id: @growth)
  end
end
