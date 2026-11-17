# frozen_string_literal: true

require "test_helper"

# The figures under each column of the timeline
# ([#452](https://github.com/espaliahq/espalia/issues/452)).
class TeamPlanning::TimelineFiguresTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: departments, effective_on: "2025-01-01")

      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                               country: "Mu", cost_centre: "Platform")
      people.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)

      ReferenceCurrency.create!(currency: "EUR")
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 150_000, currency: "EUR", period: "year",
                         cost_centre: "Platform", head_count: 2)

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 1, 1))
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                                  end_state: { rule: "capacity_model", value: { families: {}, roles: { @engineer.role_id => { model: "per_fte" } } } })
    end
    operation(Operations::TeamPlanning::AddPlanMember, scenario_id: nil, person_id: @viewer.person_id, role: "viewer")
    @h1 = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, relation: "then", name: "H1", ends_on: "2026-06-30")[:scenario_id]
    @h2 = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, parent_id: @h1, relation: "then", name: "H2")[:scenario_id]
    operation(Operations::TeamPlanning::SetPosition, scenario_id: @h2, role_id: @e5.role_id, level_id: @e5.level_id, unit_id: @payments,
                                                     fte: 1, basis: "new", cost_centre: "Platform")
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@planner))

  def plan = TeamPlanningPlan.find(@plan_id)

  def operation(operation, scenario_id: @h1, **params)
    as_tenant { operation.call(context: context_for(@planner), params: { plan_id: @plan_id, scenario_id:, **params }.compact) }
  end

  def figures(as: @planner) = as_tenant { TeamPlanning::TimelineFigures.new(context: context_for(as), plan:, scenario_id: @h2).call }

  def alone(query, scenario_id, as: @planner, **) = as_tenant { query.new(context: context_for(as), plan:, scenario_id:, **).call }

  should "give each step the figures its own cost, budget and capacity reads give it" do
    result = figures

    assert_equal [ @plan_id, @h1, @h2 ], result.steps.map(&:scenario_id)
    today, *steps = result.steps
    assert_equal [ "run_rate", alone(TeamPlanning::Cost, @plan_id).scenario.total, nil ], [ today.basis, today.cost, today.budget ]
    steps.each do |step|
      assert_equal alone(TeamPlanning::Cost, step.scenario_id).parts.total, step.cost, step.scenario_id
      assert_equal alone(TeamPlanning::Budget, step.scenario_id).totals, step.budget, step.scenario_id
      split = as_tenant { TeamPlanning::Capacity.split(context: context_for(@planner), plan:, scenario_id: step.scenario_id) }
      assert_equal split.parts.total, step.capacity, step.scenario_id
    end
    assert_equal({ "per_fte" => 2r }, steps.last.capacity, "Ada and the open seat")
    assert_operator steps.last.cost.converted, :>, steps.first.cost.converted
    assert_equal [ "band_ranges", true, "EUR" ], result.to_h.values_at(:pay_view, :money, :reference_currency)
  end

  should "run a step with no end date over the months its period shows" do
    last = figures.steps.last

    assert_equal [ true, 12, Date.new(2026, 7, 1)..Date.new(2027, 6, 30) ], [ last.open_ended, last.horizon_months, last.period ]
  end

  should "show a member without the see-pay right midpoints and every head count, with no budget money" do
    result = figures(as: @viewer)
    step = result.steps.last
    held = figures.steps.last

    assert_equal [ "band_midpoints", false ], result.to_h.values_at(:pay_view, :money)
    assert_equal alone(TeamPlanning::Cost, @h2, as: @viewer).parts.total, step.cost
    assert_equal [ nil, nil, nil ], [ step.budget.approved, step.budget.funded, step.budget.unfunded ]
    assert_equal held.budget.unfunded_heads, step.budget.unfunded_heads
  end

  # Each preset judges a different figure: the line, the cost centre or the total.
  { "position_control" => [ -> { BudgetLine.update_all(amount: 1_000) }, ->(budget) { budget.lines.first.over } ],
    "cost_centre" => [ -> { }, ->(budget) { budget.cost_centres.fetch("Platform").over } ],
    "envelope" => [ -> { }, ->(budget) { budget.totals.over } ] }.each do |preset, (overspend, judged)|
    should "mark a step over where the Budget tab does under #{preset}" do
      as_tenant do
        overspend.call
        handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                                    end_state: { rule: "budget_strictness", value: { "preset" => preset } })
      end

      assert_equal [ "EUR" ], judged.(alone(TeamPlanning::Budget, @h2)).money
      assert_nil judged.(alone(TeamPlanning::Budget, @h1))&.money.presence
      assert_equal [ nil, nil, [ "EUR" ] ], figures.steps.map { it.over&.money }
    end
  end

  should "resolve each step once" do
    calls = Hash.new(0)
    original = TeamPlanning::Resolution.instance_method(:resolved)
    TeamPlanning::Resolution.define_method(:resolved) do |*args|
      calls[@scenario_id] += 1
      original.bind_call(self, *args)
    end
    figures

    assert_equal({ @plan_id => 1, @h1 => 1, @h2 => 1 }, calls)
  ensure
    TeamPlanning::Resolution.define_method(:resolved, original)
  end

  should "refuse a capacity split read without its baseline" do
    split = as_tenant { TeamPlanning::Capacity.split(context: context_for(@planner), plan:, scenario_id: @h1, baseline: false) }

    assert_nil split.baseline
    assert_raises(ArgumentError) { split.parts }
  end
end
