# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CostTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 1, 1)

  # Test-only forecast kinds, standing in for those 10.2 to 10.4 add.
  class Hiring < TeamPlanning::ForecastKind
    def self.rule_name = "test_hiring"
    def self.description = "What each unit's forecast hires cost"
    def self.default = { "per_unit" => "0" }

    def self.forecast(frame)
      frame.map.units.filter_map do |unit|
        per_unit = Rational(frame.rule_at(unit.id)["per_unit"])
        frame.row(unit_id: unit.id, cost_centre: "CC-F", headcount: 1r, cost: { "NZD" => per_unit }, capacity: { "per_fte" => 1r }) if per_unit.positive?
      end
    end
  end

  class Leaving < TeamPlanning::ForecastKind
    def self.rule_name = "test_leaving"
    def self.description = "A tenth of everyone no planned change covers leaves"
    def self.default = {}

    def self.forecast(frame) = frame.map.people.reject { frame.covered?(it.id) }.map { frame.row(unit_id: nil, headcount: Rational(-1, 10)) }
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
      @manager = create(:framework_role, code: "EM", name: "Engineering Manager", track: "management")
      @em5 = create(:framework_level, role_id: @manager.role_id, ordinal: 5, title: "Manager")

      structure.define_taxonomy([ { level_id: departments, name: "Department" }, { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, parent_id: @engineering, effective_on: "2025-01-01")

      @ada, @brook, @cy, @dee = %w[Ada Brook Cy Dee].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                               country: "Mu", cost_centre: "CC-1")
      people.record_person(@brook.id, **ESPALIA, employment_status: "employed", title: "Engineering Manager", level: "5", fte: 0.8,
                                                 country: "Atlantis")
      people.record_person(@cy.id, **ESPALIA, employment_status: "employed", title: "Juggler", level: "5", fte: 1.0)
      people.record_person(@dee.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5",
                                               country: "Atlantis", cost_centre: "CC-2")
      people.set_membership(@ada.id, @engineering, **ESPALIA, allocation: 1.0)
      people.set_membership(@brook.id, @engineering, **ESPALIA, allocation: 0.5)
      people.set_membership(@brook.id, @payments, **ESPALIA, allocation: 0.5)
      people.set_membership(@cy.id, @payments, **ESPALIA, allocation: 1.0)
      people.set_membership(@dee.id, @payments, **ESPALIA, allocation: 1.0)

      band(@e5, "EUR", "year", 100_000)
      band(@e5, "NZD", "month", 10_000, location: "Atlantis")
      band(@e6, "EUR", "year", 130_000)
      band(@em5, "EUR", "hour", 50)
      ReferenceCurrency.create!(currency: "EUR")
      @rate = ExchangeRate.create!(from_currency: "NZD", to_currency: "EUR", rate: "0.5", applies_from: "2025-01-01")

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
    end
    @year = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@planner))

  def band(level, currency, period, midpoint, location: nil)
    PayBand.create!(level:, location:, currency:, period:, minimum: 0, midpoint:, maximum: midpoint * 2)
  end

  def operation(operation, scenario_id: @year, **params)
    as_tenant { operation.call(context: context_for(@planner), params: { plan_id: @plan_id, scenario_id:, **params }.compact) }
  end

  def open_position(level: @e5, unit_id: @engineering, fte: 1, basis: "new")
    operation(Operations::TeamPlanning::SetPosition, role_id: level.role_id, level_id: level.level_id, unit_id:, fte:, basis:)[:position_id]
  end

  def cost(scenario_id = @year)
    as_tenant { TeamPlanning::Cost.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id:).call }
  end

  def lines(priced, seat_id) = priced.lines.select { it.seat_id == seat_id }

  def with_kinds(*kinds)
    kinds.each { TeamPlanning::RuleKinds.register(it) }
    yield
  ensure
    kinds.each { TeamPlanning::RuleKinds.unregister(it) }
  end

  def add_up(parts) = [ parts.actual, parts.planned, parts.forecast ].reduce { TeamPlanning::Cost.plus(_1, _2) }

  # A part may name a currency at zero that the total doesn't.
  def assert_adds_up(parts, message = nil)
    sum = add_up(parts)
    (sum.native.keys | parts.total.native.keys).each do |currency|
      assert_equal parts.total.native.fetch(currency, 0r), sum.native.fetch(currency, 0r), "#{message} #{currency}"
    end
    assert_equal parts.total.converted, sum.converted, message
  end

  def amounts(priced, seat_id) = lines(priced, seat_id).map(&:amount)

  should "price each seat at its band's midpoint for a full-time year, by level and country, in the band's own currency" do
    report = cost

    assert_equal BASE_ON..Date.new(2026, 12, 31), report.period
    assert_equal [ 100_000r ], amounts(report.scenario, @ada.id)
    assert_equal [ 41_600r, 41_600r ], amounts(report.scenario, @brook.id), "an hourly band at 2080 hours, at 0.8 FTE, split by allocation"
    assert_equal [ 120_000r ], amounts(report.scenario, @dee.id), "the country's own band, monthly"
    assert_equal({ "EUR" => 183_200r, "NZD" => 120_000r }, report.scenario.total.native)

    ada = lines(report.scenario, @ada.id).sole
    assert_equal [ "own", "Any location", 365, 1r ], [ ada.level_source, ada.band.location_name, ada.days, ada.share ]
    assert_equal [ "Atlantis", 2_080r ], [ lines(report.scenario, @dee.id).sole.band.location_name, lines(report.scenario, @brook.id).first.hours_per_year ]
  end

  should "convert each total once, to the reference currency at the period's start, exactly" do
    report = cost

    assert_equal "EUR", report.reference_currency
    assert_equal 243_200r, report.scenario.total.converted
    assert_kind_of Rational, report.scenario.total.converted
  end

  should "leave a total unconverted and name the missing rate, never a partial sum" do
    as_tenant { @rate.destroy! }
    total = cost.scenario.total

    assert_nil total.converted
    assert_equal [ "There is no exchange rate from NZD to EUR in force on 2026-01-01" ], total.missing
    assert_equal({ "EUR" => 183_200r, "NZD" => 120_000r }, total.native)
  end

  should "list a seat no band prices as unpriced with its reason, and never count it as zero" do
    report = cost

    assert_equal [ [ @cy.id, "no_level" ] ], report.scenario.unpriced.map { [ it.seat_id, it.reason ] }
    assert_nil lines(report.scenario, @cy.id).sole.amount

    as_tenant { PayBand.where(level_id: @em5.level_id).destroy_all }
    assert_equal %w[no_band no_band], lines(cost.scenario, @brook.id).map(&:reason)
  end

  should "sum units, cost centres and the grand total to the same figure, with no unit and no cost centre counted" do
    place_cy = open_position(unit_id: @payments)
    operation(Operations::TeamPlanning::SetAssignment, person_id: @cy.id, placements: [ { position_id: place_cy, allocation: 1 } ])
    operation(Operations::TeamPlanning::SetAssignment, person_id: @ada.id, placements: [])
    open_position(unit_id: @engineering, fte: 0.5)

    [ cost.scenario, cost.baseline ].each do |priced|
      [ priced.units, priced.cost_centres ].each do |buckets|
        assert_equal priced.total.native, buckets.values.flat_map { it.native.to_a }.group_by(&:first).transform_values { it.sum(&:last) }.sort.to_h
        assert_equal priced.total.converted, buckets.values.sum(&:converted)
      end
    end
    scenario = cost.scenario
    assert_includes scenario.units.keys, nil, "Ada, placed nowhere, counts under no unit"
    assert_includes scenario.cost_centres.keys, nil
    assert_equal scenario.total.converted - scenario.units[nil].converted, scenario.units_with_below[@engineering].converted,
                 "Payments sits under Engineering, and only Ada is in no unit"
  end

  def cost_centre_rules(*rules, unit_id: nil)
    operation(Operations::TeamPlanning::SetRule, unit_id:, rule: "cost_centre", value: { rules: })
  end

  def open_cost_centre(priced, position_id) = lines(priced, position_id).sole.then { [ it.cost_centre, it.cost_centre_source, it.cost_centre_rule ] }

  should "put an open seat under its position's own cost centre first, then an occupant's" do
    labelled = operation(Operations::TeamPlanning::SetPosition, role_id: @engineer.role_id, level_id: @e5.level_id, unit_id: @payments,
                                                                fte: 1, basis: "new", cost_centre: "Platform")[:position_id]
    shared = open_position(unit_id: @payments)
    operation(Operations::TeamPlanning::SetAssignment, person_id: @ada.id, placements: [ { position_id: labelled, allocation: 0.5 },
                                                                                        { position_id: shared, allocation: 0.5 } ])
    cost_centre_rules({ unit_id: @engineering, cost_centre: "Engineering" })

    assert_equal [ "Platform", "position", nil ], open_cost_centre(cost.scenario, labelled), "its own label beats Ada's CC-1"
    assert_equal [ "CC-1", "person", nil ], open_cost_centre(cost.scenario, shared), "Ada fills half of it and brings CC-1"
  end

  should "put an unfilled position under the first cost centre rule that matches at its unit, and none without one" do
    seat = open_position(unit_id: @payments)
    assert_equal [ nil, "none", nil ], open_cost_centre(cost.scenario, seat)

    cost_centre_rules({ role_id: @manager.role_id, cost_centre: "Managers" },
                      { unit_id: @engineering, role_family_id: @engineer.role_family_id, cost_centre: "Engineering" },
                      { unit_id: @payments, cost_centre: "Payments" })

    assert_equal [ "Engineering", "rule", 1 ], open_cost_centre(cost.scenario, seat), "Payments sits under Engineering"
    assert_includes cost.scenario.cost_centres.keys, "Engineering"
  end

  should "never move a person's own cost centre by the rules" do
    cost_centre_rules({ unit_id: @engineering, cost_centre: "Engineering" })

    assert_equal [ [ nil, "none" ] ], lines(cost.scenario, @cy.id).map { [ it.cost_centre, it.cost_centre_source ] }.uniq
    assert_equal [ [ "CC-1", "person" ] ], lines(cost.scenario, @ada.id).map { [ it.cost_centre, it.cost_centre_source ] }.uniq
  end

  should "give a placeholder hire their position's cost centre, as they have none of their own" do
    seat = operation(Operations::TeamPlanning::SetPosition, role_id: @engineer.role_id, level_id: @e5.level_id, unit_id: @payments,
                                                            fte: 1, basis: "new", cost_centre: "Platform")[:position_id]
    hire = operation(Operations::TeamPlanning::SetPlaceholderHire, label: "Payments engineer", fte: 1)[:placeholder_id]
    operation(Operations::TeamPlanning::SetAssignment, person_id: hire, placements: [ { position_id: seat, allocation: 1 } ])

    assert_equal [ [ "Platform", "position" ] ], lines(cost.scenario, hire).map { [ it.cost_centre, it.cost_centre_source ] }.uniq
  end

  should "price a filled position at its occupant's level, falling back to the position's and saying so" do
    seat = open_position(level: @e6, unit_id: @payments)
    operation(Operations::TeamPlanning::SetAssignment, person_id: @cy.id, placements: [ { position_id: seat, allocation: 1 } ])
    operation(Operations::TeamPlanning::SetAssignment, person_id: @ada.id, placements: [ { position_id: seat, allocation: 1 } ])
    scenario = cost.scenario

    assert_equal [ [ @e6.level_id, "position", 130_000r ] ], lines(scenario, @cy.id).map { [ it.level_id, it.level_source, it.amount ] }
    assert_equal [ [ @e5.level_id, "own", 100_000r ] ], lines(scenario, @ada.id).map { [ it.level_id, it.level_source, it.amount ] }
    assert_empty lines(scenario, seat), "two people fill it, so no open seat costs anything"
  end

  should "price a planned promotion at the planned level" do
    operation(Operations::TeamPlanning::SetPlannedLevel, person_id: @ada.id, level: "6")
    ada = lines(cost.scenario, @ada.id).sole

    assert_equal [ @e6.level_id, "planned", 130_000r ], [ ada.level_id, ada.level_source, ada.amount ]
  end

  should "split a seat at the leaving date, so a leaver and their backfill cost one seat between them" do
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: seat, leaves_on: "2026-07-01")
    report = cost
    ada, backfill = lines(report.scenario, @ada.id).sole, lines(report.scenario, seat).sole

    assert_equal [ BASE_ON..Date.new(2026, 7, 1), Date.new(2026, 7, 2)..Date.new(2026, 12, 31) ], [ ada.held, backfill.held ]
    assert_equal 100_000r, ada.amount + backfill.amount
    assert_equal({ "EUR" => 0r, "NZD" => 0r }, report.difference.native)
  end

  should "have a leaver with no date cost nothing in the step, and their backfill the whole of it" do
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: seat)
    scenario = cost.scenario

    assert_equal [ 0r ], amounts(scenario, @ada.id)
    assert_equal [ 100_000r ], amounts(scenario, seat)
  end

  should "have a backfill replace a leaver with no date before one with a date" do
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetAssignment, person_id: @dee.id, placements: [])
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: seat, leaves_on: "2026-07-01")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @dee.id, position_id: seat)

    assert_equal [ [ 1r, BASE_ON..Date.new(2026, 12, 31) ] ], lines(cost.scenario, seat).map { [ it.fte, it.held ] }
  end

  should "open each leaver's part of a backfill the day after that leaver goes" do
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: seat, leaves_on: "2026-09-30")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @brook.id, position_id: seat, leaves_on: "2026-06-30")

    assert_equal [ [ 0.8r, Date.new(2026, 7, 1)..Date.new(2026, 12, 31) ], [ 0.2r, Date.new(2026, 10, 1)..Date.new(2026, 12, 31) ] ],
                 lines(cost.scenario, seat).map { [ it.fte, it.held ] }
  end

  should "hold all step the part of a backfill no leaver opens" do
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @brook.id, position_id: seat, leaves_on: "2026-07-01")

    assert_equal [ [ 0.8r, Date.new(2026, 7, 2)..Date.new(2026, 12, 31) ], [ 0.2r, BASE_ON..Date.new(2026, 12, 31) ] ],
                 lines(cost.scenario, seat).map { [ it.fte, it.held ] }
  end

  should "never hold a backfill before its step starts, when a moved period leaves the leaving date behind it" do
    later = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, parent_id: @year, relation: "then", name: "2027",
                                                              ends_on: "2027-12-31")[:scenario_id]
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, scenario_id: later, person_id: @ada.id, position_id: seat, leaves_on: "2027-03-31")
    operation(Operations::TeamPlanning::SetScenarioPeriod, ends_on: "2027-06-30")
    scenario = cost(later).scenario

    assert_equal Date.new(2027, 7, 1)..Date.new(2027, 12, 31), lines(scenario, seat).sole.held
    assert_equal [ 0 ], lines(scenario, @ada.id).map(&:days)
  end

  should "set the scenario beside the baseline over the same days, with the difference" do
    open_position(unit_id: @payments, fte: 0.5)
    report = cost

    assert_equal({ "EUR" => 183_200r, "NZD" => 120_000r }, report.baseline.total.native)
    assert_equal({ "EUR" => 50_000r, "NZD" => 0r }, report.difference.native)
    assert_equal 50_000r, report.difference.converted
  end

  should "add the on-cost its unit's rule sets, scaled with the seat, and read hours from the working-hours rule" do
    operation(Operations::TeamPlanning::SetRule, unit_id: @engineering, rule: "on_cost", value: { model: "flat", params: { percent: "10" } })
    operation(Operations::TeamPlanning::SetRule, unit_id: @payments, rule: "working_hours", value: { hours_per_year: "1950" })
    scenario = cost.scenario

    assert_equal [ 110_000r ], amounts(scenario, @ada.id)
    assert_equal [ [ 45_760r, 2_080r ], [ 39_000r + 3_900r, 1_950r ] ],
                 lines(scenario, @brook.id).sort_by { it.unit_id == @engineering ? 0 : 1 }.map { [ it.amount, it.hours_per_year ] },
                 "Payments sits under Engineering, so it takes Engineering's on-cost"
    assert_equal [ "10% of base pay" ], lines(scenario, @ada.id).sole.on_cost.working.map(&:label)
  end

  should "list a seat its on-cost rule can't price as unpriced, and still price the rest" do
    fixed = { model: "itemised", params: { items: [ { name: "Laptop", amount: "2000", currency: "EUR" } ] } }
    operation(Operations::TeamPlanning::SetRule, unit_id: @payments, rule: "on_cost", value: fixed)
    scenario = cost.scenario

    dee = lines(scenario, @dee.id).sole
    assert_equal [ "on_cost_refused", 120_000r, nil ], [ dee.reason, dee.base, dee.amount ]
    assert_equal 41_600r + 800r, lines(scenario, @brook.id).find { it.unit_id == @payments }.amount, "a EUR seat takes the fixed amount at its share"
    assert_equal({ "EUR" => 184_000r }, scenario.total.native)
  end

  should "state when the bands last changed, since a plan reprices live" do
    travel_to Time.utc(2026, 1, 5, 9)
    as_tenant { PayBand.find_by(level_id: @e5.level_id, location_key: "").update!(midpoint: 110_000) }

    report = cost
    assert_equal Time.utc(2026, 1, 5, 9), report.bands_changed_at
    assert_equal [ 110_000r ], amounts(report.scenario, @ada.id)

    travel_to Time.utc(2026, 1, 6, 9)
    as_tenant { PayBand.find_by(level_id: @e6.level_id).destroy! }
    assert_equal Time.utc(2026, 1, 6, 9), cost.bands_changed_at, "a removed band reprices plans too"
  end

  should "price Today for the year from its base date, with nothing to stand against" do
    report = cost(@plan_id)

    assert_equal [ "run_rate", BASE_ON..Date.new(2026, 12, 31) ], [ report.basis, report.period ]
    assert_equal 243_200r, report.scenario.total.converted
    assert_nil report.baseline
    assert_nil report.difference
  end

  should "count a year with 29 February in it as one full year, and end a year from 29 February on 28 February" do
    plan_id = SecureRandom.uuid_v7
    as_tenant { handler.create_plan(plan_id, name: "Leap", base_on: Date.new(2027, 6, 1)) }
    report = as_tenant { TeamPlanning::Cost.new(context: context_for(@planner), plan: TeamPlanningPlan.find(plan_id), scenario_id: plan_id).call }

    assert_equal Date.new(2027, 6, 1)..Date.new(2028, 5, 31), report.period
    assert_equal [ 366, 1r, 100_000r ], lines(report.scenario, @ada.id).sole.then { [ it.days, it.share, it.amount ] }
    assert_equal Date.new(2028, 2, 29)..Date.new(2029, 2, 28), TeamPlanning::Cost.year_from(Date.new(2028, 2, 29))
  end

  should "price Today's run rate first among every scenario, each scenario still against Today over its own days" do
    half = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, parent_id: @year, relation: "then", name: "Half", ends_on: "2027-06-30")[:scenario_id]
    reports = as_tenant { TeamPlanning::Cost.every_scenario(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id)) }

    assert_equal [ @plan_id, @year, half ], reports.keys
    ada = reports[half].baseline.lines.find { it.seat_id == @ada.id }
    assert_equal [ Date.new(2027, 1, 1)..Date.new(2027, 6, 30), Rational(181, 365) ], [ ada.held, ada.share ]
  end

  context "actual, planned and forecast" do
    setup do
      @moved = operation(Operations::TeamPlanning::SetAssignment, person_id: @ada.id, placements: [ { unit_id: @payments, allocation: 1 } ])
      open_position(unit_id: @payments, fte: 0.5)
    end

    should "add up to every total exactly, per unit, unit with those below, cost centre and plan" do
      with_kinds(Hiring) do
        operation(Operations::TeamPlanning::SetRule, rule: "test_hiring", value: { per_unit: "1000" })
        report = cost

        assert_equal 2, report.forecast.rows.size
        assert_equal({ "NZD" => 2000r }, report.parts.forecast.native)
        assert_equal 1000r, report.parts.forecast.converted
        assert_equal report.scenario.total.converted + 1000r, report.parts.total.converted
        assert_adds_up report.parts, "plan"
        [ :units, :units_with_below, :cost_centres ].each do |scope|
          keys = [ report.scenario, report.baseline, report.forecast ].flat_map { it.public_send(scope).keys }.uniq
          keys.each { assert_adds_up report.parts(scope, it), "#{scope} #{it}" }
        end
        assert_equal report.parts.total.converted, [ nil, @engineering ].sum { report.parts(:units_with_below, it).total.converted || report.parts(:units, it).total.converted },
                     "no unit and Engineering with those below hold the whole plan"
      end
    end

    should "have no forecast with no forecast kind, and planned the difference from Today in every total" do
      report = cost

      assert_empty report.forecast.rows
      [ [ :total, nil ], [ :units, @engineering ], [ :units, @payments ], [ :units_with_below, @engineering ], [ :cost_centres, "CC-1" ], [ :cost_centres, nil ] ].each do |scope, key|
        parts = scope == :total ? report.parts : report.parts(scope, key)
        scenario, baseline = [ report.scenario, report.baseline ].map { scope == :total ? it.total : it.public_send(scope)[key] }
        assert_equal TeamPlanning::Cost.difference(scenario, baseline), parts.planned, "#{scope} #{key}"
        assert_equal [ {}, 0r ], [ parts.forecast.native, parts.forecast.converted ]
        assert_equal scenario, parts.total
      end
      assert_equal report.difference, TeamPlanning::Cost.plus(report.parts.planned, report.parts.forecast)
    end

    should "keep someone moved as actual in the old unit with a negative planned there, and positive planned in the new" do
      report = cost
      engineering, payments = [ @engineering, @payments ].map { report.parts(:units, it) }

      assert_equal 100_000r + 41_600r, engineering.actual.native["EUR"], "Ada and half of Brook, at the base date"
      assert_equal(-100_000r, engineering.planned.native["EUR"])
      assert_equal 150_000r, payments.planned.native["EUR"], "Ada, and the half-time position"
      assert_equal 50_000r, report.parts.planned.native["EUR"], "the move nets to nothing; only the position is new"
      assert_equal report.parts(:units_with_below, @engineering).planned.native["EUR"], report.parts.planned.native["EUR"]
    end

    should "be all actual for Today's run rate" do
      with_kinds(Hiring) do
        operation(Operations::TeamPlanning::SetRule, scenario_id: @plan_id, rule: "test_hiring", value: { per_unit: "1000" })
        parts = cost(@plan_id).parts

        assert_equal [ cost(@plan_id).scenario.total ] * 2, [ parts.actual, parts.total ]
        assert_equal [ {}, {} ], [ parts.planned.native, parts.forecast.native ]
        assert_empty cost(@plan_id).forecast.rows, "Today has no period, so no step to forecast"
      end
    end
  end

  context "the forecast frame" do
    should "forecast a row per unit and step with no id, person or position, writing nothing" do
      with_kinds(Hiring) do
        operation(Operations::TeamPlanning::SetRule, unit_id: @payments, rule: "test_hiring", value: { per_unit: "500" })
        log = -> { as_tenant { TeamPlanning::Repository.new.load_plan(@plan_id).log_of(@year).map(&:event_id) } }
        before = log.()
        rows = nil
        assert_no_difference(-> { Rails.configuration.event_store.read.count }) { rows = cost.forecast.rows }

        assert_equal [ [ "test_hiring", @payments, BASE_ON, Date.new(2026, 12, 31), { "NZD" => 500r } ] ],
                     rows.map { it.to_h.values_at(:kind, :unit_id, :starts_on, :ends_on, :cost) }, "the scenario's period is the one step"
        assert_empty TeamPlanning::Forecast::Row.members & %i[id event_id subject_id person_id position_id]
        assert_equal before, log.(), "nothing joins the change list"
      end
    end

    should "leave out of a forecast anyone a planned change in the scenario's chain covers" do
      with_kinds(Leaving) do
        assert_equal 4, cost.forecast.rows.size
        operation(Operations::TeamPlanning::SetDeparture, scenario_id: @plan_id, person_id: @cy.id)
        child = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, parent_id: @year, relation: "then", name: "2027",
                                                                  ends_on: "2027-12-31")[:scenario_id]
        operation(Operations::TeamPlanning::SetDeparture, person_id: @dee.id)

        assert_equal 2, cost(child).forecast.rows.size, "Cy leaves in the baseline and Dee in its parent"
        assert_equal Rational(-2, 10), cost(child).forecast.rows.sum(&:headcount)
      end
    end

    should "only hold forecast kinds among the rule kinds that forecast" do
      with_kinds(Hiring) do
        assert_includes TeamPlanning::RuleKinds.forecasts, Hiring
        assert_equal [ Hiring ], TeamPlanning::RuleKinds.forecasts, "no built-in kind forecasts yet"
        assert_includes TeamPlanning::RuleKinds.all, Hiring
      end
    end
  end
end
