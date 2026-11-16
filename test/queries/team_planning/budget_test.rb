# frozen_string_literal: true

require "test_helper"

class TeamPlanning::BudgetTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  YEAR = { starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new" }.freeze

  class Hiring < TeamPlanning::ForecastKind
    def self.rule_name = "test_budget_hiring"
    def self.description = "What each unit's forecast hires cost"
    def self.default = { "per_unit" => "0" }

    def self.forecast(frame)
      frame.map.units.map { frame.row(unit_id: it.id, cost_centre: "CC-F", headcount: 1r, cost: { "EUR" => Rational(frame.rule_at(it.id)["per_unit"]) }) }
    end

    def self.json_schema = { type: "object", properties: { per_unit: { type: "string" } }, required: %w[per_unit], additionalProperties: false }

    def self.check(value) = value
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments, teams = Array.new(2) { SecureRandom.uuid_v7 }
    @engineering, @payments = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      @e6 = create(:framework_level, role_id: @engineer.role_id, ordinal: 6, title: "Staff SWE")

      structure.define_taxonomy([ { level_id: departments, name: "Department" }, { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, parent_id: @engineering, effective_on: "2025-01-01")

      @ada, @brook = %w[Ada Brook].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                               country: "Mu", cost_centre: "CC-1")
      people.record_person(@brook.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                                 country: "Atlantis", cost_centre: "Platform")
      people.set_membership(@ada.id, @engineering, **ESPALIA, allocation: 1.0)
      people.set_membership(@brook.id, @payments, **ESPALIA, allocation: 1.0)

      ReferenceCurrency.create!(currency: "EUR")
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      TeamPlanning::CommandHandler.new(actor: context_for(@planner)).create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 1, 1))
    end
    @year = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def operation(operation, scenario_id: @year, **params)
    as_tenant { operation.call(context: context_for(@planner), params: { plan_id: @plan_id, scenario_id:, **params }.compact) }
  end

  def open_position(level: @e5, unit_id: @payments, fte: 1, cost_centre: "Platform")
    operation(Operations::TeamPlanning::SetPosition, role_id: level.role_id, level_id: level.level_id, unit_id:, fte:, basis: "new", cost_centre:)[:position_id]
  end

  def line(**attributes) = as_tenant { BudgetLine.create!(**YEAR, **attributes).id }

  def euros(amount, **attributes) = line(amount:, currency: "EUR", period: "year", **attributes)

  def fill(position_id, person) = operation(Operations::TeamPlanning::SetAssignment, person_id: person.id, placements: [ { position_id:, allocation: 1 } ])

  def budget
    as_tenant { TeamPlanning::Budget.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year).call }
  end

  def cost
    as_tenant { TeamPlanning::Cost.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year).call }
  end

  def of(report, line_id) = report.lines.find { it.line.id == line_id }

  def with_kinds(*kinds)
    kinds.each { TeamPlanning::RuleKinds.register(it) }
    yield
  ensure
    kinds.each { TeamPlanning::RuleKinds.unregister(it) }
  end

  def plus(*natives) = natives.reduce({}) { |sum, native| sum.merge(native) { |_, a, b| a + b } }.reject { |_, amount| amount.zero? }.sort.to_h

  should "approve a line's amount over the days its period overlaps the scenario's, and a head count line no money" do
    yearly = euros(120_000, cost_centre: "Platform")
    monthly = line(amount: 1000, currency: "USD", period: "month", starts_on: "2026-07-01")
    counted = line(head_count: 2)
    report = budget

    assert_equal 120_000r, of(report, yearly).approved
    assert_equal 12_000r * Rational(184, 365), of(report, monthly).approved, "July to December is 184 days"
    assert_equal [ nil, nil, 2r ], [ of(report, counted).approved, of(report, counted).remaining, of(report, counted).remaining_head_count ]
    assert_equal({ "EUR" => 120_000r, "USD" => 12_000r * Rational(184, 365) }, report.totals.approved.native)
    assert_equal 2r, report.totals.head_count
  end

  should "fund each line with what its positions cost, at each draw's share, and leave the rest remaining" do
    platform = euros(250_000, cost_centre: "Platform", head_count: 3)
    open_position
    open_position(fte: 0.5)
    funded = of(budget, platform)

    assert_equal [ { "EUR" => 150_000r }, 100_000r ], [ funded.funded, funded.remaining ]
    assert_equal [ 2, 1.5r, 1.5r ], [ funded.funded_heads.positions, funded.funded_heads.fte, funded.remaining_head_count ]
    assert_equal({ "EUR" => 100_000r }, budget.cost_centres["Platform"].remaining.native)
  end

  should "fund only the days a line's period covers, and leave the rest unfunded" do
    second_half = euros(100_000, cost_centre: "Platform", starts_on: "2026-07-01")
    open_position
    report = budget
    covered = 100_000r * Rational(184, 365)

    assert_equal({ "EUR" => covered }, of(report, second_half).funded)
    assert_equal({ "EUR" => 300_000r - covered }, report.totals.unfunded.native, "January to June, plus Ada and Brook")
  end

  should "split a position's money across the lines it draws on" do
    one = euros(100_000, cost_centre: "Platform")
    other = euros(100_000, cost_centre: "Platform", role_id: @engineer.role_id)
    seat = open_position
    operation(Operations::TeamPlanning::SetPositionFunding, position_id: seat,
                                                            draws: [ { budget_line_id: one, share: "0.25" }, { budget_line_id: other, share: "0.75" } ])
    report = budget

    assert_equal [ { "EUR" => 25_000r }, { "EUR" => 75_000r } ], [ of(report, one).funded, of(report, other).funded ]
    assert_equal({ "EUR" => 100_000r }, report.totals.funded.native)
    assert_equal({ "EUR" => 200_000r }, report.totals.unfunded.native, "Ada and Brook hold no position")
  end

  should "measure funded on the basis the budget_basis rule names" do
    platform = euros(200_000, cost_centre: "Platform")
    open_position
    operation(Operations::TeamPlanning::SetRule, unit_id: @engineering, rule: "on_cost", value: { model: "flat", params: { percent: "10" } })

    assert_equal [ "inclusive", { "EUR" => 110_000r } ], budget.then { [ it.basis, of(it, platform).funded ] }

    operation(Operations::TeamPlanning::SetRule, rule: "budget_basis", value: { basis: "base_only" })

    assert_equal [ "base_only", { "EUR" => 100_000r } ], budget.then { [ it.basis, of(it, platform).funded ] }
  end

  should "add funded and unfunded up to the cost read's total, per currency, with every unit and cost centre agreeing" do
    with_kinds(Hiring) do
      platform = euros(150_000, cost_centre: "Platform")
      filled = open_position
      fill(filled, @brook)
      open_position(cost_centre: "Elsewhere")
      gone = euros(10_000, cost_centre: "Gone")
      split = open_position(fte: 0.5)
      operation(Operations::TeamPlanning::SetPositionFunding, position_id: split, draws: [ { budget_line_id: platform, share: "0.5" },
                                                                                            { budget_line_id: gone, share: "0.5" } ])
      operation(Operations::TeamPlanning::CutBudgetLine, budget_line_id: gone)
      operation(Operations::TeamPlanning::SetRule, rule: "test_budget_hiring", value: { per_unit: "1000" })
      report = budget
      totals = report.totals

      assert_equal cost.parts.total.native, plus(totals.funded.native, totals.unfunded.native)
      assert_equal({ "EUR" => 2000r }, report.forecast.native)
      assert_equal totals.unfunded.native, plus(*report.cost_centres.values.map { it.unfunded.native })
      assert_equal totals.unfunded.native, plus(*report.units.values.map { it.unfunded.native })
      assert_equal totals.funded.native, plus(*report.units.values.map { it.funded.native })
      assert_equal [ 1, 0.25r ], [ totals.funded_heads.positions, totals.funded_heads.fte - 1 ], "the filled seat whole, and a quarter of the split"
    end
  end

  should "flag a line drawn on in another currency, and keep its remaining in its own" do
    dollars = line(amount: 150_000, currency: "USD", period: "year", cost_centre: "Platform")
    open_position
    report = budget

    assert_equal [ { "EUR" => 100_000r }, [ "EUR" ], 150_000r ], of(report, dollars).then { [ it.funded, it.mismatched, it.remaining ] }
    assert_nil report.totals.approved.converted, "no USD rate, so the grand total doesn't convert"
    assert_not_empty report.totals.approved.missing
  end

  should "count a position no band prices in head count, under unpriced with no money" do
    platform = line(head_count: 2, cost_centre: "Platform")
    staff = open_position(level: @e6)
    report = budget

    assert_equal [ 1, {} ], [ of(report, platform).funded_heads.positions, of(report, platform).funded ]
    assert_equal 1r, of(report, platform).remaining_head_count
    assert_equal [ [ staff, [ "no_band" ], [ platform ] ] ], report.unpriced.map { [ it.position_id, it.reasons, it.budget_line_ids ] }
  end

  should "refuse the baseline, which has no period" do
    error = assert_raises(TeamPlanning::Error) do
      as_tenant { TeamPlanning::Budget.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @plan_id).call }
    end
    assert_match "no period", error.message
  end
end
