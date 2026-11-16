# frozen_string_literal: true

require "test_helper"

class TeamPlanning::FundingTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  YEAR = { starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", head_count: 1 }.freeze

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

      @ada, @brook, @cy = %w[Ada Brook Cy].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                               country: "Mu", cost_centre: "CC-1")
      people.record_person(@brook.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 0.8,
                                                 country: "Atlantis")
      people.record_person(@cy.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
      people.set_membership(@ada.id, @engineering, **ESPALIA, allocation: 1.0)
      people.set_membership(@brook.id, @payments, **ESPALIA, allocation: 1.0)
      people.set_membership(@cy.id, @payments, **ESPALIA, allocation: 1.0)

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

  def open_position(level: @e5, unit_id: @payments, fte: 1, basis: "new", cost_centre: nil)
    operation(Operations::TeamPlanning::SetPosition, role_id: level.role_id, level_id: level.level_id, unit_id:, fte:, basis:, cost_centre:)[:position_id]
  end

  def line(**attributes) = as_tenant { BudgetLine.create!(**YEAR, **attributes).id }

  def fill(position_id, person) = operation(Operations::TeamPlanning::SetAssignment, person_id: person.id, placements: [ { position_id:, allocation: 1 } ])

  def funding(scenario_id = @year)
    as_tenant { TeamPlanning::Funding.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id:).call }
  end

  def strictness(**value) = operation(Operations::TeamPlanning::SetRule, rule: "budget_strictness", value:)

  def of(report, position_id) = report.positions.find { it.position.id == position_id }

  def drawn_on(report, position_id) = of(report, position_id).then { [ it.draws.map(&:budget_line_id), it.reason ] }

  should "draw on a line with the position's cost centre before any line with none, however much more that one states" do
    platform = line(cost_centre: "Platform")
    line(role_id: @engineer.role_id, level_id: @e5.level_id, location: "Atlantis")
    seat = open_position(cost_centre: "Platform")
    fill(seat, @brook)

    assert_equal [ [ platform ], nil ], drawn_on(funding, seat)
  end

  should "match a line with no cost centre to any position, and prefer the one stating more of role, level and location" do
    any = line
    role = line(role_id: @engineer.role_id)
    role_and_level = line(role_id: @engineer.role_id, level_id: @e5.level_id)
    seat = open_position(cost_centre: "Platform")
    staff = open_position(level: @e6)

    assert_equal [ [ role_and_level ], nil ], drawn_on(funding, seat)
    assert_equal [ [ role ], nil ], drawn_on(funding, staff), "the E5 line doesn't match a Staff position"
    assert_includes of(funding, staff).matching_ids, role
    assert_not_includes of(funding, staff).matching_ids, any, "only the most specific tie is named"
  end

  should "leave a position matching two lines equally well unfunded, naming both and picking neither" do
    tied = [ line(role_id: @engineer.role_id), line(level_id: @e5.level_id) ].sort
    seat = open_position
    report = funding

    assert_equal [ [], "ambiguous" ], drawn_on(report, seat)
    assert_equal tied, of(report, seat).matching_ids
    assert_not of(report, seat).funded?
  end

  should "place a backfill where its leaver was, in the scenarios after the one they leave in" do
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @brook.id, position_id: seat, leaves_on: "2026-06-30")
    following = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, parent_id: @year, relation: "then", name: "2027",
                                                                   ends_on: "2027-12-31")[:scenario_id]
    atlantis = as_tenant { BudgetLine.create!(**YEAR, starts_on: "2027-01-01", ends_on: "2027-12-31", location: "Atlantis").id }

    assert_equal [ [ atlantis ], nil ], drawn_on(funding(following), seat)
  end

  should "leave a position no line matches unfunded: another cost centre, role, level or location" do
    line(cost_centre: "Elsewhere")
    line(role_id: SecureRandom.uuid_v7)
    line(level_id: @e6.level_id)
    line(location: "Mu")
    seat = open_position(cost_centre: "Platform")
    fill(seat, @brook)

    assert_equal [ [], "no_line" ], drawn_on(funding, seat), "Brook is in Atlantis, not Mu"
  end

  should "let a dimension the strictness rule frees stop blocking a line, and record where the line differs" do
    elsewhere = line(cost_centre: "Elsewhere")
    seat = open_position(cost_centre: "Platform")
    assert_equal [ [], "no_line" ], drawn_on(funding, seat), "position control holds the cost centre"

    strictness(match: %w[role level location], limit: "money", scope: "organisation")
    draw = of(funding, seat).draws.sole
    assert_equal [ elsewhere, %w[cost_centre], [] ], [ draw.budget_line_id, draw.differs_on, draw.variance ]
  end

  should "under an envelope, prefer the line whose stated dimensions agree" do
    staff_line = line(role_id: SecureRandom.uuid_v7, level_id: @e6.level_id)
    line(role_id: SecureRandom.uuid_v7)
    level = line(level_id: @e5.level_id, location: "Mu")
    seat = open_position
    staff = open_position(level: @e6)
    strictness(preset: "envelope")

    report = funding
    assert_equal [ [ level ], nil ], drawn_on(report, seat), "it agrees on level, though Mu is not where the seat is"
    assert_equal %w[location], of(report, seat).draws.sole.differs_on
    assert_equal [ [ staff_line ], nil ], drawn_on(report, staff), "it agrees on level, though its role differs"
    assert_equal [ %w[role], [] ], of(report, staff).draws.sole.then { [ it.differs_on, it.variance ] }
  end

  should "under an envelope, prefer the line that differs on fewer dimensions when none agrees" do
    line(role_id: SecureRandom.uuid_v7, level_id: @e6.level_id)
    other_role = line(role_id: SecureRandom.uuid_v7)
    seat = open_position
    strictness(preset: "envelope")

    assert_equal [ [ other_role ], nil ], drawn_on(funding, seat)
  end

  should "match and rank exactly as before under the default" do
    platform = line(cost_centre: "Platform")
    role_and_level = line(role_id: @engineer.role_id, level_id: @e5.level_id)
    seat = open_position(cost_centre: "Platform")
    loose = open_position(level: @e6, cost_centre: "Elsewhere")

    report = funding
    assert_equal "position_control", TeamPlanning::RuleKinds::BudgetStrictness.preset_of(report.strictness)
    assert_equal [ [ platform ], nil ], drawn_on(report, seat)
    assert_equal [ [], "no_line" ], drawn_on(report, loose)
    assert_not_includes report.positions.flat_map(&:matching_ids), role_and_level
    assert report.positions.flat_map(&:draws).all? { it.differs_on.empty? }
  end

  should "match a location on the country of an occupant, else of the leaver a backfill replaces, ignoring case and spacing" do
    atlantis = line(location: " atlantis ")
    filled = open_position
    fill(filled, @brook)
    seat = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: seat, leaves_on: "2026-06-30")

    report = funding
    assert_equal [ [ atlantis ], nil ], drawn_on(report, filled)
    assert_equal [ [], "no_line" ], drawn_on(report, seat), "Ada is in Mu"
    assert_equal "Mu", of(report, seat).location
  end

  should "match only a line whose period overlaps the days the position is held" do
    first_half = line(starts_on: "2026-01-01", ends_on: "2026-06-30")
    line(starts_on: "2027-01-01", ends_on: "2027-12-31")
    held_all_year = open_position
    from_july = open_position(basis: "backfill")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: from_july, leaves_on: "2026-06-30")

    report = funding
    assert_equal [ [ first_half ], nil ], drawn_on(report, held_all_year)
    assert_equal Date.new(2026, 7, 1), of(report, from_july).starts_on
    assert_equal [ [], "no_line" ], drawn_on(report, from_july)
  end

  should "leave out a backfill whose leaver goes after the months an open step shows, as it costs nothing in them" do
    seat = open_position(basis: "backfill")
    open_step = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, parent_id: @year, relation: "then", name: "2027 on")[:scenario_id]
    operation(Operations::TeamPlanning::SetDeparture, scenario_id: open_step, person_id: @cy.id, position_id: seat, leaves_on: "2028-03-31")
    budget_line = line(starts_on: "2027-01-01", ends_on: "2027-12-31")

    report = funding(open_step)
    assert_equal Date.new(2027, 12, 31), report.period.end
    assert_nil of(report, seat)
    assert_equal [ 0, 0 ], [ report.total.positions, report.total.fte ]

    budget = as_tenant { TeamPlanning::Budget.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: open_step).call }
    cost = as_tenant { TeamPlanning::Cost.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: open_step).call }
    assert_equal [ [ nil, 0 ] ], cost.scenario.lines.select { it.position_id == seat }.map { [ it.held, it.amount ] },
                 "the cost read holds it no day and prices it at nothing"
    assert_equal({}, budget.lines.find { it.line.id == budget_line }.funded)
    assert_equal [ 0, 0 ], [ budget.totals.funded_heads.positions, budget.totals.unfunded_heads.positions ]
    assert_equal [ 0, 0 ], [ budget.totals.funded_heads.fte, budget.totals.unfunded_heads.fte ]
  end

  should "hold a backfill from the period's start when a leaver has no date or leaves part of it open, as the cost read does" do
    undated, part_open = Array.new(2) { open_position(basis: "backfill") }
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: undated, leaves_on: "2026-06-30")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @cy.id, position_id: undated)
    operation(Operations::TeamPlanning::SetDeparture, person_id: @brook.id, position_id: part_open, leaves_on: "2026-06-30")

    report = funding
    assert_equal Date.new(2026, 1, 1), of(report, undated).starts_on, "Cy, with no date, opens it all step"
    assert_equal Date.new(2026, 1, 1), of(report, part_open).starts_on, "Brook opens 0.8 of it; the rest is held all step"
  end

  should "list a line's positions filled first, then backfills, then other open ones, each by the day it is first held" do
    budget = line
    open_later, open_sooner = Array.new(2) { open_position }.sort.reverse
    late_backfill, early_backfill = Array.new(2) { open_position(basis: "backfill") }
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: late_backfill, leaves_on: "2026-09-30")
    operation(Operations::TeamPlanning::SetDeparture, person_id: @brook.id, position_id: early_backfill, leaves_on: "2026-03-31")
    filled = open_position
    fill(filled, @cy)

    drawn = funding.by_line.fetch(budget).map(&:first)
    assert_equal [ filled, early_backfill, late_backfill, open_sooner, open_later ], drawn.map { it.position.id }
    assert_equal %w[filled backfill backfill open open], drawn.map(&:draw_reason)
  end

  should "let a set funding win over the derived line, and fund nothing from a line the scenario has cut" do
    derived = line(role_id: @engineer.role_id)
    other = line(cost_centre: "Elsewhere")
    seat = open_position(fte: 0.5)
    operation(Operations::TeamPlanning::SetPositionFunding, position_id: seat,
                                                            draws: [ { budget_line_id: other, share: "0.75" }, { budget_line_id: derived, share: "0.25" } ])

    report = funding
    assert_equal [ [ other, derived ], nil ], drawn_on(report, seat)
    assert_equal "set", of(report, seat).source
    assert_equal [ 0.375r ], report.by_line.fetch(other).map { |funded, draw| funded.fte * draw.share }

    operation(Operations::TeamPlanning::CutBudgetLine, budget_line_id: other)
    report = funding
    assert_equal "line_gone", of(report, seat).reason
    assert_equal [ 0.125r, 0, 0.375r ], [ report.funded.fte, report.funded.positions, report.unfunded.fte ]
    assert_not report.by_line.key?(other)
  end

  should "always add funded and unfunded up to the positions and FTE the cost read sees" do
    line(role_id: @engineer.role_id, level_id: @e5.level_id)
    line(cost_centre: "Platform")
    open_position(fte: 0.5)
    open_position(level: @e6, fte: 0.8)
    open_position(cost_centre: "Platform")
    filled = open_position
    fill(filled, @cy)
    split = open_position(fte: 0.6)
    operation(Operations::TeamPlanning::SetPositionFunding, position_id: split, draws: [ { budget_line_id: line, share: "0.5" },
                                                                                        { budget_line_id: line, share: "0.5" } ])

    positions = as_tenant { TeamPlanning::Cost.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year).call }
                  .scenario.map.positions
    report = funding
    assert_equal [ positions.size, positions.sum(0r) { Rational(it.fte.to_s) } ], [ report.total.positions, report.total.fte ]
    assert_equal report.total, TeamPlanning::Funding::Count.new(positions: report.funded.positions + report.unfunded.positions,
                                                                fte: report.funded.fte + report.unfunded.fte)
    assert report.unfunded.positions.positive?, "the Staff position matches no line"
  end

  should "compare every dimension budget_strictness names, in its order" do
    assert_equal TeamPlanning::RuleKinds::BudgetStrictness::DIMENSIONS, TeamPlanning::Funding::MATCHED.keys
  end

  should "refuse the baseline, which has no period, and a scenario the plan doesn't have" do
    assert_raises(TeamPlanning::Error, match: /baseline has no period/) { funding(@plan_id) }
    assert_raises(TeamPlanning::Error, match: /No such scenario/) { funding(SecureRandom.uuid_v7) }
  end
end
