# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::EditPositionTest < ActiveSupport::TestCase
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
      @designer = create(:framework_role, tenant: @tenant, name: "Designer")
      @d1 = create(:framework_level, tenant: @tenant, role_id: @designer.role_id, ordinal: 1, title: "Designer I")
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
                                                            level_id: @e2.level_id, unit_id: @payments, fte: 0.5, basis: "backfill",
                                                            cost_centre: "Platform")[:position_id]
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def edit(as: @editor, scenario_id: @q1, **params)
    call(Operations::TeamPlanning::EditPosition, as:, plan_id: @plan_id, scenario_id:, position_id: @position, **params)
  end

  def position(as: @editor)
    call(Operations::TeamPlanning::ScenarioMap, as:, plan_id: @plan_id, scenario_id: @q1)[:positions].find { it[:position_id] == @position }
  end

  def fields(as: @editor) = position(as:).values_at(:role_id, :level_id, :unit_id, :fte, :basis, :cost_centre).tap { it[3] = it[3].to_f }

  def refusal(**params) = assert_raises(Operations::Base::ParameterError) { edit(**params) }.message

  should "change only the fields it is given, so two edits in turn both stay" do
    edit(fte: 0.8)
    edit(role_id: @designer.role_id, level_id: @d1.level_id)

    assert_equal [ @designer.role_id, @d1.level_id, @payments, 0.8, "backfill", "Platform" ], fields
  end

  should "keep an omitted cost centre, and clear one given as null or empty" do
    edit(basis: "new")
    assert_equal "Platform", position[:cost_centre]

    edit(cost_centre: nil)
    assert_nil position[:cost_centre]
    edit(cost_centre: "Ledger")
    edit(cost_centre: "")
    assert_nil position[:cost_centre]
    assert_equal [ @engineer.role_id, @e2.level_id, @payments, 0.5, "new", nil ], fields
  end

  should "return what SetPosition returns, and write one change" do
    result = edit(unit_id: @growth)

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, position_id: @position, role_id: @engineer.role_id, level_id: @e2.level_id,
                   unit_id: @growth, fte: 0.5, basis: "backfill", cost_centre: "Platform", hiring_status: "not_started", target_start: nil,
                   budget: "committed" }, result)
  end

  should "keep a hiring status and target start an edit leaves out" do
    edit(hiring_status: "offer_accepted", target_start: "2026-05-04")
    edit(fte: 0.8)
    edit(unit_id: @growth)

    assert_equal [ "offer_accepted", "2026-05-04", 0.8, @growth ], position.values_at(:hiring_status, :target_start, :fte, :unit_id)
  end

  should "refuse an accepted offer with no target start, given or kept" do
    assert_equal "An accepted offer needs a target start", refusal(hiring_status: "offer_accepted")

    edit(hiring_status: "offer_accepted", target_start: "2026-05-04")
    assert_equal "An accepted offer needs a target start", refusal(target_start: nil)
    assert_equal [ "offer_accepted", "2026-05-04" ], position.values_at(:hiring_status, :target_start)
  end

  should "check what it writes as SetPosition does" do
    assert_equal "That level belongs to another role", refusal(role_id: @designer.role_id)
    assert_match "FTE", refusal(fte: 1.5)
    assert_match "missing required parameter: fte", refusal(fte: nil)
    assert_equal [ @engineer.role_id, @e2.level_id, @payments, 0.5, "backfill", "Platform" ], fields
  end

  should "refuse a unit outside the plan's scope" do
    call(Operations::TeamPlanning::SetPlanScope, plan_id: @plan_id, unit_ids: [ @payments ])

    assert_equal "This position is outside the units this plan covers. Place it in one of its units first.", refusal(unit_id: @growth)
  end

  should "refuse a viewer and an unknown position" do
    assert_equal "No such plan", refusal(as: @viewer, fte: 0.8)
    assert_equal "This scenario has no such position",
                 assert_raises(Operations::Base::ParameterError) {
                   call(Operations::TeamPlanning::EditPosition, plan_id: @plan_id, scenario_id: @q1, position_id: SecureRandom.uuid_v7, fte: 0.8)
                 }.message
  end

  should "keep the cost centre for an editor without the see-pay right" do
    planner = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: planner.person_id, role: "editor")
    edit(as: planner, fte: 0.8)

    assert_equal [ "Platform", 0.8 ], [ position(as: planner)[:cost_centre], position(as: planner)[:fte].to_f ]
  end
end
