# frozen_string_literal: true

require "test_helper"

# A split step is one step: its cost, capacity and timeline read as they did
# before the split, and the agreed part on its own counts its departures as
# leaving in that step.
class TeamPlanning::SplitTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      family = create(:framework_role_family, name: "Engineering")
      engineer = create(:framework_role, code: "E", name: "Software Engineer", role_family_id: family.role_family_id)
      @e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "EUR")

      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2025-01-01")
      @ada, @brook = %w[Ada Brook].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      [ @ada, @brook ].each do
        people.record_person(it.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
        people.set_membership(it.id, @engineering, **ESPALIA, allocation: 1.0)
      end

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 1, 1))
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                                  end_state: { rule: "capacity_model",
                                                                               value: { families: { family.role_family_id => { model: "per_fte" } }, roles: {} } })
    end
    @h1 = fork(@plan_id, "H1", ends_on: "2026-06-30")
    @h2 = fork(@h1, "H2", ends_on: "2026-12-31")
    @hire = operation(Operations::TeamPlanning::SetPosition, scenario_id: @h1, role_id: @e5.role_id, level_id: @e5.level_id,
                                                             unit_id: @engineering, fte: 1, basis: "new")[:position_id]
    operation(Operations::TeamPlanning::SetDeparture, scenario_id: @h1, person_id: @brook.id)
    operation(Operations::TeamPlanning::SetPosition, scenario_id: @h2, role_id: @e5.role_id, level_id: @e5.level_id,
                                                     unit_id: @engineering, fte: 0.5, basis: "new")
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context)

  def operation(operation, **params)
    as_tenant { operation.call(context:, params: { plan_id: @plan_id, **params }) }
  end

  def fork(parent_id, name, ends_on:)
    operation(Operations::TeamPlanning::ForkScenario, parent_id:, relation: "then", name:, ends_on:)[:scenario_id]
  end

  def split(*event_ids)
    SecureRandom.uuid_v7.tap { |agreed_id| as_tenant { handler.split_scenario(@plan_id, @h1, agreed_id:, name: "Agreed", event_ids:) } }
  end

  def change_on(subject_id) = TeamPlanningOverride.find_by!(scenario_id: @h1, subject_id:).event_id

  def query(kind, scenario_id) = as_tenant { kind.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id:).call }

  def counts
    [ @h1, @h2 ].to_h do |scenario_id|
      cost = query(TeamPlanning::Cost, scenario_id)
      [ scenario_id, [ cost.period, cost.scenario.total.native, query(TeamPlanning::Capacity, scenario_id).totals ] ]
    end
  end

  def timeline
    result = query(TeamPlanning::Timeline, @h2)
    [ result.columns, result.next_ids, result.maps.map { it.with(step_ids: []) }, result.blocks ]
  end

  def resolved(scenario_id)
    as_tenant { TeamPlanning::Resolution.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id:).structure }
  end

  should "cost and count the pair as the one step it was, over one period, and lay out the same timeline" do
    before = [ counts, timeline ]
    assert_equal 3, timeline.first.size

    split(change_on(@hire))

    assert_equal before, [ counts, timeline ]
  end

  should "count a departure that moves into the agreed part as leaving in its step, there and in the rest" do
    agreed = split(change_on(@brook.id))

    [ agreed, @h1 ].each do |scenario_id|
      brook = resolved(scenario_id).people.find { it.id == @brook.id }
      assert brook&.departure, "Brook leaves in this step, so the map still holds them"
    end
    assert_nil resolved(@h2).people.find { it.id == @brook.id }, "the next step has them gone"
  end
end
