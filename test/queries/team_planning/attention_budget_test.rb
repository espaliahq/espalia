# frozen_string_literal: true

require "test_helper"

# The budget checks of Team Planning 6.6
# ([#421](https://github.com/espaliahq/espalia/issues/421)): each reads the
# scenario's Budget report as the viewer, and none names an amount.
class TeamPlanning::AttentionBudgetTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  YEAR = { starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new" }.freeze
  BUDGET_CHECKS = %i[unfunded ambiguous_funding unplaced cost_centre_mismatches budget_variance unused_budget_lines].freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: @departments, name: "Department" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: @departments, effective_on: "2025-01-01")

      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0, country: "Mu")
      people.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)

      ReferenceCurrency.create!(currency: "EUR")
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      TeamPlanning::CommandHandler.new(actor: context_for(@planner)).create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 1, 1))
    end
    @year = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def operation(operation, scenario_id: @year, **params)
    as_tenant { operation.call(context: context_for(@planner), params: { plan_id: @plan_id, scenario_id:, **params }.compact) }
  end

  def open_position(cost_centre: "Platform", fte: 1)
    operation(Operations::TeamPlanning::SetPosition, role_id: @e5.role_id, level_id: @e5.level_id, unit_id: @payments, fte:, basis: "new", cost_centre:)[:position_id]
  end

  def line(**attributes) = as_tenant { BudgetLine.create!(**YEAR, amount: 1_000_000, currency: "EUR", period: "year", **attributes).id }

  def found(scenario_id: @year)
    as_tenant do
      TeamPlanning::Attention.for(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id:)
                             .items.select { BUDGET_CHECKS.include?(it.check) }
    end
  end

  def as_viewer(tenant_user)
    as_tenant do
      TeamPlanning::Attention.for(context: context_for(tenant_user), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year)
                             .items.select { BUDGET_CHECKS.include?(it.check) }.map { [ it.check, it.subject_id, it.reason ] }
    end
  end

  def seat(person, position, allocation: 1)
    operation(Operations::TeamPlanning::SetAssignment, person_id: person.id, placements: [ { position_id: position, allocation: } ])
  end

  def reasons(check) = found.select { it.check == check }.map { [ it.subject_id, it.reason ] }

  def cost_centre_entries(*entries)
    as_tenant { Operations::Tenants::SetPlanningRule.call(context: context_for(@planner), params: { rule: "cost_centre", value: { entries: } }) }
  end

  def cost_line(person)
    as_tenant { TeamPlanning::Cost.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year).call }
      .scenario.lines.find { it.seat_id == person.id }
  end

  should "check nothing about budgets in a scenario with no budget lines, or in the baseline" do
    open_position(cost_centre: nil)

    assert_empty found
    line(cost_centre: "Platform")
    assert_empty found(scenario_id: @plan_id)
  end

  should "mark a position no line matches, but not one a set funding funds" do
    platform = line(cost_centre: "Platform")
    unmatched = open_position(cost_centre: "Growth")
    set = open_position(cost_centre: "Growth")
    operation(Operations::TeamPlanning::SetPositionFunding, position_id: set, draws: [ { budget_line_id: platform } ])

    assert_equal [ [ unmatched, "No budget line matches it" ] ], reasons(:unfunded)
    assert_equal "funding", found.find { it.check == :unfunded }.facet
  end

  should "mark a position two lines could fund equally, and leave it out of unfunded" do
    line(cost_centre: "Platform")
    line(cost_centre: "Platform")
    seat = open_position

    assert_equal [ [ seat, "2 budget lines could fund it equally, and no funding is set" ] ], reasons(:ambiguous_funding)
    assert_empty reasons(:unfunded)
    assert_empty reasons(:unused_budget_lines), "the tie is the thing to fix, not the lines"
  end

  should "mark a seat with no cost centre once a line or another seat has one, and only then" do
    line
    seat = open_position(cost_centre: nil)

    assert_empty reasons(:unplaced), "nothing in the plan has a cost centre, so it uses none"

    open_position
    assert_equal [ [ seat, "Has no cost centre: no label, occupant or entry gives one" ],
                   [ @ada.id, "Has no cost centre: no position label, cost centre of their own or entry gives one" ] ].sort,
                 reasons(:unplaced).sort, "a seat's label puts the plan on cost centres, though no line names one"

    line(cost_centre: "Platform")
    assert_includes reasons(:unplaced), [ seat, "Has no cost centre: no label, occupant or entry gives one" ]
  end

  should "leave out a seat held for none of the period" do
    line(cost_centre: "Platform")
    open_position
    assert_includes reasons(:unplaced).map(&:first), @ada.id

    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id)
    assert_not_includes reasons(:unplaced).map(&:first), @ada.id, "a leaver with no date holds the seat for none of the step"
  end

  should "mark a line spent past its amount and head count, saying by how many FTE but never by how much money" do
    platform = line(cost_centre: "Platform", amount: 150_000, head_count: 1)
    2.times { open_position }

    assert_equal [ [ platform, "Spends over its approved amount and over its head count by 1 FTE" ] ], reasons(:budget_variance)
    assert_no_match(/\d{3}/, reasons(:budget_variance).sole.last)
  end

  # A budget amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)), so a line past it is too.
  should "flag a line past its amount only to a member with the see-pay right, and past its head count to every editor" do
    editor = as_tenant { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
    as_tenant { Operations::TeamPlanning::AddPlanMember.call(context: context_for(@planner), params: { plan_id: @plan_id, person_id: editor.person_id, role: "editor" }) }
    priced = line(cost_centre: "Platform", amount: 150_000, head_count: 1)
    2.times { open_position }

    assert_equal [ [ :budget_variance, priced, "Spends over its head count by 1 FTE" ] ], as_viewer(editor).select { it.first == :budget_variance }
  end

  should "mark a cost centre and the whole budget over under the strictness that judges them" do
    line(cost_centre: "Platform", amount: 150_000)
    2.times { open_position }
    operation(Operations::TeamPlanning::SetRule, rule: "budget_strictness", value: { preset: "cost_centre" })

    assert_equal [ [ "Platform", "Spends over its approved amount" ] ], reasons(:budget_variance)
    assert_equal "cost_centre", found.find { it.check == :budget_variance }.facet

    operation(Operations::TeamPlanning::SetRule, rule: "budget_strictness", value: { preset: "envelope" })
    assert_equal [ [ @plan_id, "Spends over its approved amount" ] ], reasons(:budget_variance)
  end

  should "mark the seats with no cost centre over what lines naming none approve, under the cost-centre strictness" do
    line(cost_centre: nil, amount: 150_000)
    2.times { open_position(cost_centre: nil) }
    operation(Operations::TeamPlanning::SetRule, rule: "budget_strictness", value: { preset: "cost_centre" })

    assert_equal [ [ TeamPlanning::Attention::NO_COST_CENTRE, "Spends over its approved amount" ] ], reasons(:budget_variance)
    names = as_tenant { TeamPlanning::Attention.for(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year).names }
    assert_equal "No cost centre", names[TeamPlanning::Attention::NO_COST_CENTRE]
  end

  should "touch every unit a person with no cost centre is placed in" do
    growth = SecureRandom.uuid_v7
    as_tenant { OrgGraph::StructureCommandHandler.new(actor: SYSTEM).create_unit(growth, "Growth", level_id: @departments, effective_on: "2025-01-01") }
    line
    open_position
    operation(Operations::TeamPlanning::SetAssignment, person_id: @ada.id,
                                                       placements: [ { unit_id: @payments, allocation: 0.5 }, { unit_id: growth, allocation: 0.5 } ])

    ada = found.find { it.check == :unplaced && it.subject_id == @ada.id }
    assert_equal [ @payments, growth ].sort, ada.unit_ids.sort
  end

  should "mark a line in the period nothing draws on, but not one outside it" do
    idle = line(cost_centre: "Growth")
    line(cost_centre: "Growth", starts_on: "2027-01-01", ends_on: "2027-12-31")
    line(cost_centre: "Platform")
    open_position

    assert_equal [ [ idle, "Nothing in this scenario draws on it" ] ], reasons(:unused_budget_lines)
  end

  should "name a budget line by its role, level and cost centre, and a cost centre by itself" do
    named = as_tenant { BudgetLine.new(**YEAR, head_count: 1, cost_centre: "Platform").tap { it.take_level(@e5) }.tap(&:save!) }
    report = as_tenant { TeamPlanning::Attention.for(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @year) }
    idle = report.items.find { it.check == :unused_budget_lines }

    assert_equal "#{named.role_label} · Platform", report.names[idle.subject_id]
    assert_match(/\ASoftware Engineer, .*Senior SWE · Platform\z/, report.names[idle.subject_id])
  end

  context "a person whose cost centre disagrees" do
    setup do
      as_tenant do
        @ledger = SecureRandom.uuid_v7
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM).create_unit(@ledger, "Ledger", level_id: @departments, effective_on: "2025-01-01")
        people = OrgGraph::CommandHandler.new(actor: SYSTEM)
        @bo, @cy = [ [ "Bo Reed", @payments, "Platform" ], [ "Cy Lark", @ledger, "Growth" ] ].map do |name, unit_id, cost_centre|
          create(:person, tenant: @tenant, name:).tap do |person|
            people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0, country: "Mu", cost_centre:)
            people.set_membership(person.id, unit_id, **ESPALIA, allocation: 1.0)
          end
        end
      end
      @platform = line(cost_centre: "Platform")
    end

    should "be named when they keep their real one and the entries that match them give another, and still costed there" do
      cost_centre_entries({ unit_id: @payments, cost_centre: "Payments" })

      assert_includes reasons(:cost_centre_mismatches), [ @bo.id, "Costed in Platform, while the cost centre entries give Payments" ]
      assert_not_includes reasons(:cost_centre_mismatches).map(&:first), @cy.id, "no entry matches Cy in Ledger"
      assert_equal [ "Platform", "person", "Payments" ], cost_line(@bo).then { [ it.cost_centre, it.cost_centre_source, it.rule_cost_centre ] }
    end

    should "be named against a labelled position they sit in untouched" do
      seat(@bo, open_position(cost_centre: "Growth"))

      assert_equal [ [ @bo.id, "Costed in Platform, while their position is in Growth" ] ], reasons(:cost_centre_mismatches)
    end

    should "be named when the plan moves them into a position whose untouched occupant decides it" do
      shared = open_position(cost_centre: nil)
      seat(@bo, shared, allocation: 0.5)
      seat(@cy, shared, allocation: 0.5)

      assert_equal [ [ @cy.id, "Costed in Growth, while their position is in Platform" ] ], reasons(:cost_centre_mismatches),
                   "Bo stays put and decides the position; Cy's move brings Growth to their own cost line only"
    end

    should "be named against a line their position draws on that is approved for another cost centre" do
      growth = line(cost_centre: "Growth")
      position = open_position(cost_centre: nil)
      seat(@bo, position)
      assert_empty reasons(:cost_centre_mismatches), "Bo decides the position, which draws on Platform"

      operation(Operations::TeamPlanning::SetPositionFunding, position_id: position, draws: [ { budget_line_id: growth } ])
      assert_equal [ [ @bo.id, "Costed in Platform, while their position draws on a budget line for Growth" ] ], reasons(:cost_centre_mismatches)
      assert_match(/Funding/, found.find { it.check == :cost_centre_mismatches }.change.class.name, "the funding that draws on Growth explains it")
    end

    should "name the cost centre of the seat that disagrees when a person is costed in two" do
      cost_centre_entries({ unit_id: @payments, cost_centre: "Payments" })
      labelled = open_position(cost_centre: "Platform")
      ruled = open_position(cost_centre: nil)
      operation(Operations::TeamPlanning::SetAssignment, person_id: @cy.id,
                                                         placements: [ { position_id: labelled, allocation: 0.5 }, { position_id: ruled, allocation: 0.5 } ])
      operation(Operations::TeamPlanning::SetPositionFunding, position_id: ruled, draws: [ { budget_line_id: @platform } ])

      assert_equal [ [ @cy.id, "Costed in Payments, while their position draws on a budget line for Platform" ] ],
                   reasons(:cost_centre_mismatches).select { it.first == @cy.id }
    end

    should "give the entries' cost centre only to a person who keeps a real one the entries disagree with" do
      cost_centre_entries({ unit_id: @payments, cost_centre: "Platform" }, { unit_id: @ledger, cost_centre: "Payments" })
      seat(@cy, open_position(cost_centre: nil))

      assert_equal [ "Platform", "person", nil ], cost_line(@bo).then { [ it.cost_centre, it.cost_centre_source, it.rule_cost_centre ] },
                   "Bo's entries agree with his own"
      assert_equal [ "Platform", "rule", nil ], cost_line(@cy).then { [ it.cost_centre, it.cost_centre_source, it.rule_cost_centre ] },
                   "the plan moved Cy, so the entries decide"
      assert_empty reasons(:cost_centre_mismatches)
    end

    should "name only cost centres a scoped plan holds" do
      line(cost_centre: "Growth")
      cost_centre_entries({ unit_id: @payments, cost_centre: "Payments" })
      operation(Operations::TeamPlanning::SetPlanScope, unit_ids: [ @payments ])

      assert_equal [ [ @bo.id, "Costed in Platform, while the cost centre entries give Payments" ] ], reasons(:cost_centre_mismatches),
                   "Cy, costed in Growth, sits outside the scope"
      assert_empty found.map(&:reason).grep(/Growth/), "nor does any budget item name Growth, a cost centre the plan doesn't hold"
    end

    should "read the same for a member without the see-pay right" do
      editor = as_tenant { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
      as_tenant { Operations::TeamPlanning::AddPlanMember.call(context: context_for(@planner), params: { plan_id: @plan_id, person_id: editor.person_id, role: "editor" }) }
      cost_centre_entries({ unit_id: @payments, cost_centre: "Payments" })
      shared = open_position(cost_centre: nil)
      seat(@bo, shared, allocation: 0.5)
      seat(@cy, shared, allocation: 0.5)
      operation(Operations::TeamPlanning::SetPositionFunding, position_id: shared, draws: [ { budget_line_id: line(cost_centre: "Ledger") } ])

      mismatches = ->(viewer) { as_viewer(viewer).select { it.first == :cost_centre_mismatches } }
      assert_equal 4, mismatches.(@planner).size, mismatches.(@planner).inspect
      assert_equal mismatches.(@planner), mismatches.(editor)
    end
  end

  context "for a plan member without the see-pay right" do
    setup do
      as_tenant do
        @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
        Operations::TeamPlanning::AddPlanMember.call(context: context_for(@planner), params: { plan_id: @plan_id, person_id: @editor.person_id, role: "editor" })
      end
      @line = line(cost_centre: "Platform", amount: 150_000)
      @seat = open_position
      2.times { line(cost_centre: "Growth") }
      open_position(cost_centre: "Growth")
      line(cost_centre: "Spare")
      open_position(cost_centre: "Atlantis")
      open_position(cost_centre: nil)
      operation(Operations::TeamPlanning::SetAssignment, person_id: @ada.id, placements: [ { position_id: @seat, allocation: 1 } ])
      operation(Operations::TeamPlanning::SetActualPay, person_id: @ada.id, amount: "180000", currency: "EUR", period: "year", basis: "full_time")
    end

    should "push a line over on held pay only for the holder, and read every other item alike" do
      holder = as_viewer(@planner)
      editor = as_viewer(@editor)

      assert_includes holder, [ :budget_variance, @line, "Spends over its approved amount" ], "held pay is past the line's amount"
      assert_not editor.any? { it.first == :budget_variance && it.second == @line }, "the band's midpoint is not"
      assert_equal holder.reject { it.first == :budget_variance }, editor.reject { it.first == :budget_variance }
      assert holder.map(&:first).to_set >= %i[unfunded ambiguous_funding unplaced unused_budget_lines].to_set, holder.inspect
      assert_empty (holder + editor).map(&:last).grep(/\d{3}|EUR/), "no item names an amount"
    end
  end
end
