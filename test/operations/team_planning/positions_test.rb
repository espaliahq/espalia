# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::PositionsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      @designer = create(:framework_role, tenant: @tenant, name: "Designer")
      @d1 = create(:framework_level, tenant: @tenant, role_id: @designer.role_id, ordinal: 1, title: "Designer I")
    end
    @unit_id = SecureRandom.uuid_v7
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2027-01-01")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = fork(relation: "then", name: "Q1", ends_on: "2027-03-31")
    @lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")
    @q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2027-06-30")
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def open_position(scenario_id, **params)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id:, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id: @unit_id, fte: 1, basis: "new", **params)
  end

  def close(scenario_id, position_id) = call(Operations::TeamPlanning::ClosePosition, plan_id: @plan_id, scenario_id:, position_id:)

  def positions(scenario_id, as: @admin) = call(Operations::TeamPlanning::Positions, as:, plan_id: @plan_id, scenario_id:)[:positions]

  def refusal(operation, as: @admin, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, plan_id: @plan_id, **params) }.message
  end

  should "open a position with its budget, and list it with the framework's names" do
    opened = open_position(@q1, basis: "backfill", fte: 0.5)
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, position_id: opened[:position_id], role_id: @engineer.role_id,
                   level_id: @e2.level_id, unit_id: @unit_id, fte: 0.5, basis: "backfill", cost_centre: nil, hiring_status: "not_started",
                   target_start: nil, budget: "committed" }, opened)

    assert_equal [ { position_id: opened[:position_id], role_id: @engineer.role_id, level_id: @e2.level_id, unit_id: @unit_id,
                     fte: 0.5, basis: "backfill", cost_centre: nil, role_name: "Software Engineer", level_name: "Engineer II",
                     hiring_status: "not_started", target_start: nil, opens_on: "2027-01-01", budget: "committed",
                     occupants: [], open_fte: 0.5, backfill_for_ids: [] } ],
                 positions(@q1)

    planned = open_position(@q1)[:position_id]
    assert_equal "planned", positions(@q1).find { it[:position_id] == planned }[:budget]
  end

  should "store and list a hiring status and target start, and when each seat opened" do
    opened = open_position(@q1, hiring_status: "offer_accepted", target_start: "2027-02-15")
    assert_equal({ hiring_status: "offer_accepted", target_start: "2027-02-15" }, opened.slice(:hiring_status, :target_start))
    open_position(@q2)
    today = open_position(@plan_id)

    listed = positions(@q2).index_by { it[:position_id] }
    assert_equal [ "offer_accepted", "2027-02-15", "2027-01-01" ], listed[opened[:position_id]].values_at(:hiring_status, :target_start, :opens_on)
    assert_equal "2027-04-01", positions(@q2).find { it[:position_id] != opened[:position_id] && it[:position_id] != today[:position_id] }[:opens_on]
    assert_equal "2027-01-01", listed[today[:position_id]][:opens_on]
    assert_equal "An accepted offer needs a target start",
                 refusal(Operations::TeamPlanning::SetPosition, scenario_id: @q1, role_id: @engineer.role_id, level_id: @e2.level_id,
                                                                unit_id: @unit_id, fte: 1, basis: "new", hiring_status: "offer_accepted")
  end

  should "open a backfill on the day after its leaver goes" do
    seat = open_position(@q1, basis: "backfill")[:position_id]
    leaver = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
    call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: @q1, person_id: leaver.id, position_id: seat, leaves_on: "2027-02-19")

    assert_equal "2027-02-20", positions(@q1).sole[:opens_on]
  end

  should "store and list the position's own cost centre" do
    opened = open_position(@q1, cost_centre: " Platform ")

    assert_equal "Platform", opened[:cost_centre]
    assert_equal [ "Platform" ], positions(@q1).pluck(:cost_centre)
  end

  should "reach the steps after it and the alternatives to it, and never the scenario before" do
    position_id = open_position(@q1)[:position_id]

    assert_empty positions(@plan_id)
    [ @q1, @lean, @q2 ].each { assert_equal [ position_id ], positions(it).pluck(:position_id) }
  end

  should "let an alternative change its parent's position without touching the parent" do
    position_id = open_position(@q1)[:position_id]
    open_position(@lean, position_id:, role_id: @designer.role_id, level_id: @d1.level_id, fte: 0.6)

    assert_equal [ [ "Designer", 0.6 ] ], positions(@lean).map { it.values_at(:role_name, :fte) }
    assert_equal [ [ "Software Engineer", 1.0 ] ], positions(@q1).map { it.values_at(:role_name, :fte) }
    assert_equal [ [ "Software Engineer", 1.0 ] ], positions(@q2).map { it.values_at(:role_name, :fte) }
  end

  should "close a position for the steps after, and reopen it with a later set" do
    position_id = open_position(@q1)[:position_id]

    assert_equal({ plan_id: @plan_id, scenario_id: @q2, position_id:, closed: true }, close(@q2, position_id))
    assert_empty positions(@q2)
    assert_equal [ position_id ], positions(@q1).pluck(:position_id)
    assert_equal "This scenario has no such open position",
                 refusal(Operations::TeamPlanning::ClosePosition, scenario_id: @q2, position_id:)

    open_position(@q2, position_id:, basis: "backfill")
    assert_equal [ [ position_id, "committed" ] ], positions(@q2).map { it.values_at(:position_id, :budget) }
  end

  should "refuse a role or level the framework lacks, a level of another role, and a position the scenario lacks" do
    assert_equal "No such role", refusal(Operations::TeamPlanning::SetPosition, scenario_id: @q1, role_id: SecureRandom.uuid_v7,
                                                                                level_id: @e2.level_id, unit_id: @unit_id, fte: 1, basis: "new")
    assert_equal "No such level", refusal(Operations::TeamPlanning::SetPosition, scenario_id: @q1, role_id: @engineer.role_id,
                                                                                 level_id: SecureRandom.uuid_v7, unit_id: @unit_id, fte: 1, basis: "new")
    assert_equal "That level belongs to another role",
                 refusal(Operations::TeamPlanning::SetPosition, scenario_id: @q1, role_id: @engineer.role_id,
                                                                level_id: @d1.level_id, unit_id: @unit_id, fte: 1, basis: "new")

    position_id = open_position(@q2)[:position_id]
    assert_equal "This scenario has no such position",
                 refusal(Operations::TeamPlanning::SetPosition, scenario_id: @q1, position_id:, role_id: @engineer.role_id,
                                                                level_id: @e2.level_id, unit_id: @unit_id, fte: 1, basis: "new")
    assert_equal "This scenario has no such open position",
                 refusal(Operations::TeamPlanning::ClosePosition, scenario_id: @q1, position_id:)
  end

  should "refuse an FTE outside (0, 1] and an unknown basis" do
    [ 0, 1.5, -0.5 ].each do |fte|
      assert_raises(Operations::Base::ParameterError, fte.to_s) { open_position(@q1, fte:) }
    end
    assert_raises(Operations::Base::ParameterError) { open_position(@q1, basis: "contractor") }
  end

  should "read as missing to an admin outside the plan, and refuse a viewer's writes" do
    position_id = open_position(@q1)[:position_id]
    set = { scenario_id: @q1, role_id: @engineer.role_id, level_id: @e2.level_id, unit_id: @unit_id, fte: 1, basis: "new" }

    [ [ Operations::TeamPlanning::Positions, { scenario_id: @q1 } ],
      [ Operations::TeamPlanning::SetPosition, set ],
      [ Operations::TeamPlanning::ClosePosition, { scenario_id: @q1, position_id: } ] ].each do |operation, params|
      assert_equal "No such plan", refusal(operation, as: @other_admin, **params), operation.name
    end

    assert_equal [ position_id ], positions(@q1, as: @viewer).pluck(:position_id)
    assert_equal "No such plan", refusal(Operations::TeamPlanning::SetPosition, as: @viewer, **set)
    assert_equal "No such plan", refusal(Operations::TeamPlanning::ClosePosition, as: @viewer, scenario_id: @q1, position_id:)
  end

  should "never name another tenant's role or level" do
    other = create(:tenant)
    elsewhere = ActsAsTenant.with_tenant(other) do
      role = create(:framework_role, tenant: other)
      [ role, create(:framework_level, tenant: other, role_id: role.role_id) ]
    end

    assert_equal "No such role", refusal(Operations::TeamPlanning::SetPosition, scenario_id: @q1, role_id: elsewhere.first.role_id,
                                                                                level_id: elsewhere.last.level_id, unit_id: @unit_id, fte: 1, basis: "new")
  end
end
