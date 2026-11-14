# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanDataTest < ActiveSupport::TestCase
  include Operations::TeamPlanning::MapPayload

  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: SYSTEM)
        .record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer", level: "3")

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @q2 = fork(@q1, "then", "Q2", ends_on: "2026-09-30")
      @hire = SecureRandom.uuid_v7
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@planner))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set(kind, scenario_id = @q1, subject_id: @ada.id, **end_state)
    as_tenant { handler.set_change(@plan_id, kind, scenario_id:, subject_id:, end_state:) }
  end

  def map(scenario_id = @q1)
    as_tenant { TeamPlanning::Resolution.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id:).call }
  end

  def ada(scenario_id = @q1) = map(scenario_id).people.find { it.id == @ada.id }

  def hire(scenario_id = @q1) = map(scenario_id).people.find { it.id == @hire }

  def forget_ada = as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }

  def delete_plan_keys = as_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }

  def promote_and_correct
    set(TeamPlanning::Events::LevelSet, level: "4")
    set(TeamPlanning::Events::PlanDataSet, field: "fte", value: "0.8")
  end

  def add_hire(**end_state) = set(TeamPlanning::Events::PlaceholderSet, subject_id: @hire, label: "Payments engineer", level: "3", fte: 0.5, **end_state)

  should "land a planned level and a plan value on the map, follow them into a later step and let the last change win" do
    promote_and_correct

    assert_equal [ 4, 0.8 ].map(&:to_s), [ ada.planned_or_own(:level), ada.planned_or_own(:fte) ].map(&:to_s)
    assert_equal "4", ada(@q2).planned_or_own(:level)
    assert_equal "3", ada(@plan_id).planned_or_own(:level)

    set(TeamPlanning::Events::LevelSet, @q2, level: "5")

    assert_equal "5", ada(@q2).planned_or_own(:level)
    assert_equal "4", ada.planned_or_own(:level)
  end

  should "prefer a planned promotion to a corrected level, and a corrected level to the Org Graph's" do
    set(TeamPlanning::Events::PlanDataSet, field: "level", value: "2")

    assert_equal "2", ada.planned_or_own(:level)

    set(TeamPlanning::Events::LevelSet, level: "4")

    assert_equal "4", ada.planned_or_own(:level)
  end

  should "seal a person's values in the event store, never in clear" do
    promote_and_correct
    raw = ActiveRecord::Base.connection.select_values("SELECT convert_from(data, 'UTF8') FROM event_store_events WHERE event_type LIKE 'TeamPlanning::Events::%Set'")

    assert_equal 2, raw.size
    assert raw.none? { it.include?("\"4\"") || it.include?("0.8") }, "a sealed value was stored in clear"
  end

  should "read a forgotten person's planned values as unknown, never raising and never falling back to the Org Graph" do
    promote_and_correct
    add_hire
    forget_ada

    assert_equal [ TeamPlanning::Baseline::UNKNOWN ] * 2, [ ada.planned_or_own(:level), ada.planned_or_own(:fte) ]
    assert_equal "Payments engineer", hire.placeholder.reveal
    assert_equal [ "3", 0.5 ], [ hire.planned_or_own(:level), hire.planned_or_own(:fte) ]
  end

  should "shred a placeholder with its plan's keys, reading it as unknown" do
    add_hire
    delete_plan_keys

    assert hire.placeholder.removed?
    assert_equal TeamPlanning::Baseline::UNKNOWN, hire.planned_or_own(:level)
    assert_equal "Placeholder hire", as_tenant { names_for(map) }.fetch(@hire)
  end

  should "show sealed values in the map payload by value, and a removed one as removed" do
    promote_and_correct
    add_hire

    person = as_tenant { map_payload(map) }[:people].find { it[:id] == @ada.id }
    assert_equal({ value: "4" }, person[:planned_level])
    assert_equal({ fte: { value: 0.8 } }, person[:plan_data])
    assert_equal "Payments engineer", as_tenant { map_payload(map) }[:names].fetch(@hire)

    forget_ada
    person = as_tenant { map_payload(map) }[:people].find { it[:id] == @ada.id }
    assert_equal({ removed: true }, person[:planned_level])
    assert_nothing_raised { as_tenant { map_payload(map) }.to_json }
  end

  should "count a planned FTE in capacity, and a removed one as not known" do
    set(TeamPlanning::Events::PlanDataSet, field: "fte", value: "0.5")
    seat = -> { as_tenant { TeamPlanning::Capacity.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @q1).call }.seats.find { it.seat.id == @ada.id }.seat }

    assert_equal [ 0.5r, true ], [ seat.call.fte, seat.call.fte_known ]

    forget_ada

    assert_equal [ 1r, false ], [ seat.call.fte, seat.call.fte_known ]
  end

  should "read a planned level's status, and unknown once its value is removed" do
    set(TeamPlanning::Events::LevelSet, level: "4")
    status = -> { as_tenant { TeamPlanning::Status.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @q1).call }.statuses.find { it.facet == "level" }.status }

    assert_equal :pending, status.call

    forget_ada

    assert_equal :unknown, status.call
  end

  should "refuse to pin a sealed value" do
    promote_and_correct
    error = assert_raises(TeamPlanning::Error) { as_tenant { handler.pin_change(@plan_id, scenario_id: @q2, subject_id: @ada.id, facet: "level") } }

    assert_match "can't be pinned yet", error.message
  end
end
