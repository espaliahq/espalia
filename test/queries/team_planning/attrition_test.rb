# frozen_string_literal: true

require "test_helper"

# Attrition takes away the empty days of filled seats, per unit and cost
# centre, priced at the unit's average filled seat
# ([#362](https://github.com/espaliahq/espalia/issues/362)). A year-long step
# of 365 days keeps the figures easy to follow.
class TeamPlanning::AttritionTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments = departments = SecureRandom.uuid_v7
    teams = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7
    @platform = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      family = create(:framework_role_family, name: "Engineering")
      engineer = create(:framework_role, code: "E", name: "Software Engineer", role_family_id: family.role_family_id)
      @e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "EUR")

      structure.define_taxonomy([ { level_id: departments, name: "Department" }, { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2025-01-01")
      structure.create_unit(@platform, "Platform", level_id: teams, parent_id: @engineering, effective_on: "2025-01-01")
      @ada, @brook, @cy, @dee = %w[Ada Brook Cy Dee].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      { @ada => [ @engineering, 1.0, "CC-1" ], @brook => [ @engineering, 1.0, "CC-1" ], @cy => [ @engineering, 0.5, "CC-2" ],
        @dee => [ @platform, 1.0, nil ] }.each do |person, (unit_id, fte, cost_centre)|
        people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte:, cost_centre:)
        people.set_membership(person.id, unit_id, **ESPALIA, allocation: 1.0)
      end

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 1, 1))
      rule(@plan_id, "capacity_model", { families: { family.role_family_id => { model: "per_fte" } }, roles: {} })
    end
    @year = operation(Operations::TeamPlanning::ForkScenario, parent_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    operation(Operations::TeamPlanning::SetDeparture, scenario_id: @year, person_id: @brook.id)
    operation(Operations::TeamPlanning::SetPosition, scenario_id: @year, role_id: @e5.role_id, level_id: @e5.level_id,
                                                     unit_id: @engineering, fte: 1, basis: "new")
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def org = as_tenant { yield OrgGraph::CommandHandler.new(actor: SYSTEM) }

  def context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context)

  def operation(operation, **params)
    as_tenant { operation.call(context:, params: { plan_id: @plan_id, **params }) }
  end

  def rule(subject_id, rule, value)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id:, end_state: { rule:, value: })
    end
  end

  def plan = TeamPlanningPlan.find(@plan_id)

  def cost = as_tenant { TeamPlanning::Cost.new(context:, plan:, scenario_id: @year).call }

  def capacity = as_tenant { TeamPlanning::Capacity.split(context:, plan:, scenario_id: @year) }

  def rows = cost.forecast.rows.to_h { [ [ it.unit_id, it.cost_centre ], it ] }

  def capacities = capacity.forecast.to_h { [ [ it.unit_id, it.cost_centre ], it.capacity.transform_values { decimal(it) } ] }

  def add_up(parts) = [ parts.actual, parts.planned, parts.forecast ].reduce { TeamPlanning::Cost.plus(_1, _2) }

  def decimal(value) = BigDecimal(value, 20)

  context "with a plan-wide rate, and a nearer one for Platform" do
    setup do
      rule(@plan_id, "attrition", { yearly_rate: "0.1" })
      rule(@plan_id, "time_to_hire", { days: "73" })
      rule(@platform, "attrition", { yearly_rate: "0.2" })
      rule(@platform, "time_to_hire", { days: "400" })
    end

    should "take away the empty days of filled seats, per unit and cost centre, leaving out the leaver and the open position" do
      # Ada alone fills CC-1 once Brook leaves: 0.1 × 1 FTE / 365 × (73 × 365 − 73² / 2) = 6.57 FTE-days.
      ada = rows.fetch([ @engineering, "CC-1" ])
      assert_equal [ Date.new(2026, 1, 1), Date.new(2026, 12, 31) ], [ ada.starts_on, ada.ends_on ]
      assert_equal decimal("-0.02"), decimal(ada.headcount)
      assert_equal({ "EUR" => decimal("-1800") }, ada.cost.transform_values { decimal(it) })

      cy = rows.fetch([ @engineering, "CC-2" ])
      assert_equal decimal("-0.01"), decimal(cy.headcount)
      assert_equal({ "EUR" => decimal("-900") }, cy.cost.transform_values { decimal(it) })

      # A time to hire as long as the step leaves a seat empty to its end: 0.2 / 365 × 365² / 2 = 36.5 FTE-days.
      dee = rows.fetch([ @platform, nil ])
      assert_equal decimal("-0.2"), decimal(dee.headcount)
      assert_equal({ "EUR" => decimal("-10000") }, dee.cost.transform_values { decimal(it) })

      assert_equal({ [ @engineering, "CC-1" ] => { "per_fte" => decimal("-0.018") }, [ @engineering, "CC-2" ] => { "per_fte" => decimal("-0.009") },
                     [ @platform, nil ] => { "per_fte" => decimal("-0.1") } }, capacities)
      assert(rows.values.all? { it.capacity.empty? }, "cost measures no capacity, so its rows carry none")
      assert_equal 3, rows.size, "Brook leaves and the position is open, so neither is in the base"
      assert(cost.forecast.rows.all? { it.kind == "attrition" })
    end

    should "keep actual, planned and forecast adding up to the total, per unit and overall" do
      report = cost
      [ [ :total, nil ], [ :units, @engineering ], [ :units, @platform ], [ :units_with_below, @engineering ],
        [ :cost_centres, "CC-1" ], [ :cost_centres, nil ] ].each do |scope, key|
        parts = report.parts(scope, key)
        assert_equal parts.total.native, add_up(parts).native, "#{scope} #{key}"
      end
      assert_equal(-12_700r, report.parts.forecast.native.fetch("EUR"))

      split = capacity
      [ nil, @engineering, @platform ].each do |unit_id|
        parts = split.parts(unit_id)
        assert_equal parts.total, TeamPlanning::Capacity.add([ parts.actual, parts.planned, parts.forecast ]), unit_id.inspect
      end
      assert_equal({ "per_fte" => Rational(-127, 1000) }, split.parts.forecast)
    end

    should "price at the average of a unit's filled seats, on-cost and all" do
      rule(@plan_id, "on_cost", { model: "flat", params: { percent: "10" } })
      assert_equal({ "EUR" => decimal("-11000") }, rows.fetch([ @platform, nil ]).cost.transform_values { decimal(it) })
    end

    should "leave out anyone a planned change covers, and forecast nothing for Today" do
      operation(Operations::TeamPlanning::SetDeparture, scenario_id: @year, person_id: @dee.id)
      assert_not rows.key?([ @platform, nil ])
      assert_empty as_tenant { TeamPlanning::Cost.new(context:, plan:, scenario_id: @plan_id).call }.forecast.rows
    end
  end

  context "at 20% with a year to hire, priced at the average over every filled seat" do
    setup do
      rule(@plan_id, "attrition", { yearly_rate: "0.2" })
      rule(@plan_id, "time_to_hire", { days: "365" })
    end

    should "count an unpriced seat in the unit's FTE and not its figure, so the unit loses no more than it costs" do
      eve = as_tenant { create(:person, tenant: @tenant, name: "Eve Quill") }
      org do |people|
        people.record_person(eve.id, **ESPALIA, employment_status: "employed")
        people.set_membership(eve.id, @platform, **ESPALIA, allocation: 1.0)
      end
      platform = rows.fetch([ @platform, nil ])

      assert_equal decimal("-0.4"), decimal(platform.headcount)
      assert_equal({ "EUR" => decimal("-10000") }, platform.cost.transform_values { decimal(it) })
      assert_equal({ "per_fte" => decimal("-0.1") }, capacities.fetch([ @platform, nil ]))
    end

    should "take away what a part-allocated seat delivers, not a whole FTE's capacity" do
      org { it.set_membership(@dee.id, @platform, **ESPALIA, allocation: 0.5) }

      assert_equal({ "per_fte" => decimal("-0.05") }, capacities.fetch([ @platform, nil ]))
    end

    should "leave out a place outside a scoped plan, as cost does" do
      data = SecureRandom.uuid_v7
      as_tenant { OrgGraph::StructureCommandHandler.new(actor: SYSTEM).create_unit(data, "Data", level_id: @departments, effective_on: "2025-01-01") }
      org do |people|
        people.set_membership(@dee.id, @platform, **ESPALIA, allocation: 0.5)
        people.set_membership(@dee.id, data, **ESPALIA, allocation: 0.5)
      end
      operation(Operations::TeamPlanning::SetPlanScope, unit_ids: [ @engineering ])

      assert_not rows.key?([ nil, nil ]), "Dee's place in Data is outside the plan"
      assert_equal decimal("-0.1"), decimal(rows.fetch([ @platform, nil ]).headcount)
    end

    should "forecast nothing with no time to hire, as no seat stays empty" do
      rule(@plan_id, "time_to_hire", { days: "0" })

      assert_empty cost.forecast.rows
    end
  end

  should "forecast nothing at the default rate of 0" do
    assert_empty cost.forecast.rows
  end
end
