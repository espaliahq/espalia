# frozen_string_literal: true

require "test_helper"

# Cost, capacity and the headcount walk read one rule for when an open seat
# starts ([#458](https://github.com/espaliahq/espalia/issues/458)): a seat has
# started in a step when its start falls on or before the step's last day.
class Operations::TeamPlanning::SeatStartTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @unit_id = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5)
      add_pay_band!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      squads = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@unit_id, "Payments", level_id: squads, effective_on: "2026-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                            value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    @q2 = fork(relation: "then", name: "Q2", ends_on: "2026-06-30")
    @q3 = fork(parent_id: @q2, relation: "then", name: "Q3", ends_on: "2026-09-30")
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def open_position(**hiring)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q2, role_id: @engineer.role_id,
                                                level_id: @e5.level_id, unit_id: @unit_id, fte: 1, basis: "new", **hiring)[:position_id]
  end

  # What the seat costs in the step, over how many days, and what it delivers.
  def figures(scenario_id, seat_id)
    cost = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id:, unit_id: @unit_id)[:seats][:scenario].find { it[:seat_id] == seat_id }
    place = call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id:)[:seats].find { it[:seat_id] == seat_id }[:places].sole
    [ cost[:days], place[:capacity], place[:reason] ]
  end

  def walk(scenario_id = @q3) = call(Operations::TeamPlanning::Timeline, plan_id: @plan_id, scenario_id:)[:walk].pluck(:hires)

  should "count an undated seat from the step that opens it, as before" do
    seat = open_position

    assert_equal [ 121, "1", nil ], figures(@q2, seat)
    assert_equal [ 92, "1", nil ], figures(@q3, seat)
  end

  should "start a seat whose target falls inside a step in full for capacity, and cost it from the start" do
    seat = open_position(target_start: "2026-06-01")

    assert_equal [ 30, "1", nil ], figures(@q2, seat)
    assert_equal [ 92, "1", nil ], figures(@q3, seat)
  end

  should "leave a seat that starts after the step's last day out of it, without listing it as unclassified" do
    seat = open_position(hiring_status: "offer_accepted", target_start: "2026-07-01")

    assert_equal [ 0, nil, "not_started" ], figures(@q2, seat)
    assert_empty call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id: @q2)[:unclassified]
    assert_equal [ 92, "1", nil ], figures(@q3, seat)
  end

  should "leave a seat out of every step while recruiting is on hold" do
    seat = open_position(hiring_status: "on_hold", target_start: "2026-05-01")

    assert_equal [ 0, nil, "not_started" ], figures(@q2, seat)
    assert_equal [ 0, nil, "not_started" ], figures(@q3, seat)
  end

  should "count a placeholder in a dated seat as a hire in the step the seat starts" do
    seat = open_position(target_start: "2026-08-03")
    hire = call(Operations::TeamPlanning::SetPlaceholderHire, plan_id: @plan_id, scenario_id: @q2, label: "Backend hire")[:placeholder_id]
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @q2, person_id: hire,
                                                  placements: [ { position_id: seat, allocation: 1 } ])

    assert_equal [ nil, 0, 1 ], walk
    assert_equal [ 0, nil, "not_started" ], figures(@q2, hire)
    assert_equal [ 59, "1", nil ], figures(@q3, hire)
  end
end
