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

  def rule(subject_id, rule, value, scenario_id: @plan_id)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id:, end_state: { rule:, value: })
    end
  end

  def position(unit_id, level: @e5)
    operation(Operations::TeamPlanning::SetPosition, scenario_id: @year, role_id: level.role_id, level_id: level.level_id,
                                                     unit_id:, fte: 1, basis: "new")[:position_id]
  end

  def plan = TeamPlanningPlan.find(@plan_id)

  def cost = as_tenant { TeamPlanning::Cost.new(context:, plan:, scenario_id: @year).call }

  def capacity = as_tenant { TeamPlanning::Capacity.split(context:, plan:, scenario_id: @year) }

  def rows = cost.forecast.rows.to_h { [ [ it.unit_id, it.cost_centre ], it ] }

  def capacities = capacity.forecast.to_h { [ [ it.unit_id, it.cost_centre ], it.capacity.transform_values { decimal(it) } ] }

  def add_up(parts) = [ parts.actual, parts.planned, parts.forecast ].reduce { TeamPlanning::Cost.plus(_1, _2) }

  def decimal(value) = BigDecimal(value, 20)

  def step(parent_id, name, ends_on)
    operation(Operations::TeamPlanning::ForkScenario, parent_id:, relation: "then", name:, ends_on:)[:scenario_id]
  end

  def cost_in(scenario_id) = as_tenant { TeamPlanning::Cost.new(context:, plan:, scenario_id:).call }

  def step_row(scenario_id) = cost_in(scenario_id).forecast.rows.find { it.unit_id == @platform }

  def capacities_in(scenario_id)
    as_tenant { TeamPlanning::Capacity.split(context:, plan:, scenario_id:) }.forecast
                                                                            .to_h { [ [ it.unit_id, it.cost_centre ], it.capacity.transform_values { decimal(it) } ] }
  end

  def assert_vacancy(row, headcount:, empty_days:)
    assert_equal decimal(headcount), decimal(row.headcount)
    assert_equal({ "EUR" => -100_000 * Rational(empty_days) / 365 }, row.cost)
  end

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

    should "take away a year of each seat still empty on the last day from the run rate at the end" do
      # The steady share of seats waiting to be filled: Ada's CC-1 has 0.02 FTE empty, at the unit's average of EUR 100k.
      assert_equal({ [ @engineering, "CC-1" ] => decimal("-2000"), [ @engineering, "CC-2" ] => decimal("-1000"), [ @platform, nil ] => decimal("-20000") },
                   rows.transform_values { decimal(it.run_rate.fetch("EUR")) })
      assert_equal decimal("-23000"), decimal(cost.at_end_parts.forecast.converted)
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

    should "take away a person's capacity in a unit once, however many of its positions they fill" do
      seats = 2.times.map { position(@platform) }
      operation(Operations::TeamPlanning::SetAssignment, scenario_id: @year, person_id: @dee.id,
                                                         placements: seats.map { { position_id: it, allocation: 0.5 } })

      assert_equal({ "per_fte" => decimal("-0.1") }, capacities.fetch([ @platform, nil ]))
    end

    should "price a half left unpriced at nothing, not at the priced half's rate" do
      e6 = as_tenant { create(:framework_level, role_id: @e5.role_id, ordinal: 6, title: "Staff SWE") }
      eve = as_tenant { create(:person, tenant: @tenant, name: "Eve Quill") }
      org do |people|
        people.record_person(eve.id, **ESPALIA, employment_status: "employed")
        people.set_membership(eve.id, @platform, **ESPALIA, allocation: 1.0)
      end
      operation(Operations::TeamPlanning::SetAssignment, scenario_id: @year, person_id: eve.id,
                                                         placements: [ { position_id: position(@platform), allocation: 0.5 },
                                                                       { position_id: position(@platform, level: e6), allocation: 0.5 } ])

      assert_equal({ "EUR" => decimal("-15000") }, rows.fetch([ @platform, nil ]).cost.transform_values { decimal(it) })
    end

    should "forecast nothing with no time to hire, as no seat stays empty" do
      rule(@plan_id, "time_to_hire", { days: "0" })

      assert_empty cost.forecast.rows
    end
  end

  # Three 90-day steps from 1 January. Platform loses 0.73 of Dee's FTE a
  # year, 0.002 FTE a day, priced at the E5 midpoint of 100,000 EUR.
  context "across back-to-back steps" do
    setup do
      operation(Operations::TeamPlanning::SetScenarioPeriod, scenario_id: @year, ends_on: "2026-03-31")
      @first = @year
      @second = step(@first, "Q2", "2026-06-29")
      rule(@platform, "attrition", { yearly_rate: "0.73" })
    end

    should "read step 1 only while a seat its leavers empty can still be waiting in step 2" do
      defaults = TeamPlanning::RuleKinds.defaults.merge("time_to_hire" => { "days" => "0" })
      reaching = -> { as_tenant { TeamPlanning::Forecast.reaching(TeamPlanning::Repository.new.load_plan(@plan_id), @second, defaults:) } }

      assert_empty reaching.(), "no time to hire, so every seat is backfilled the day it empties"
      rule(@platform, "time_to_hire", { days: "1" })
      assert_equal [ @first ], reaching.()
    end

    should "take away step 1's seats still empty in step 2, beside step 2's own" do
      rule(@platform, "time_to_hire", { days: "180" })

      # 0.002 × 90² / 2 = 8.1 FTE-days in step 1, as before.
      assert_vacancy step_row(@first), headcount: "-0.18", empty_days: "8.1"
      # Step 2's own 8.1, and every seat step 1 emptied stays empty all 90 days:
      # 0.002 × 90 × 90 = 16.2 more. Without the carry it took away 8.1 alone.
      assert_vacancy step_row(@second), headcount: "-0.36", empty_days: "24.3"
      assert_equal({ [ @platform, nil ] => { "per_fte" => decimal("-0.27") } }, capacities_in(@second))
    end

    should "carry only the seats still empty, and none past the time to hire" do
      rule(@platform, "time_to_hire", { days: "30" })
      third = step(@second, "Q3", "2026-09-27")

      # Each step's own 0.002 × (30 × 90 − 30² / 2) = 4.5, and 0.002 × 30² / 2 =
      # 0.9 from the step before; nothing from two steps back.
      assert_vacancy step_row(@first), headcount: "-0.06", empty_days: "4.5"
      [ @second, third ].each { assert_vacancy step_row(it), headcount: "-0.06", empty_days: "5.4" }
    end

    should "carry step 1's leavers into a step 2 that sets no rate of its own" do
      rule(@platform, "time_to_hire", { days: "180" })
      rule(@platform, "attrition", { yearly_rate: "0" }, scenario_id: @second)

      assert_vacancy step_row(@second), headcount: "-0.18", empty_days: "16.2"
    end

    should "keep actual, planned and forecast adding up to the total in step 2, per unit and overall, and price every scenario alike" do
      rule(@plan_id, "attrition", { yearly_rate: "0.1" })
      rule(@platform, "time_to_hire", { days: "180" })
      report = cost_in(@second)
      [ [ :total, nil ], [ :units, @engineering ], [ :units, @platform ], [ :units_with_below, @engineering ],
        [ :cost_centres, "CC-1" ], [ :cost_centres, nil ] ].each do |scope, key|
        parts = report.parts(scope, key)
        assert_equal parts.total.native, add_up(parts).native, "#{scope} #{key}"
      end

      split = as_tenant { TeamPlanning::Capacity.split(context:, plan:, scenario_id: @second) }
      [ nil, @engineering, @platform ].each do |unit_id|
        parts = split.parts(unit_id)
        assert_equal parts.total, TeamPlanning::Capacity.add([ parts.actual, parts.planned, parts.forecast ]), unit_id.inspect
      end

      every = as_tenant { TeamPlanning::Cost.every_scenario(context:, plan:) }
      [ @first, @second ].each { assert_equal cost_in(it).forecast.rows, every.fetch(it).forecast.rows }
    end

    should "list the carried figures in the forecast tool, cost and capacity together" do
      rule(@platform, "time_to_hire", { days: "180" })
      row = operation(Operations::TeamPlanning::Forecast, scenario_id: @second)[:rows].find { it[:unit_id] == @platform }

      assert_equal [ "-0.36", { "per_fte" => "-0.27" } ], row.values_at(:headcount, :capacity)
      assert_equal decimal(-100_000 * Rational(243, 10) / 365).round(10), decimal(row[:cost].fetch("EUR")).round(10)
    end
  end

  should "forecast nothing at the default rate of 0" do
    assert_empty cost.forecast.rows
  end
end
