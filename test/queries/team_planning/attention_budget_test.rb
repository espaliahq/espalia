# frozen_string_literal: true

require "test_helper"

# The budget checks of Team Planning 6.6
# ([#421](https://github.com/espaliahq/espalia/issues/421)): each reads the
# scenario's Budget report as the viewer, and none names an amount.
class TeamPlanning::AttentionBudgetTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  YEAR = { starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new" }.freeze
  BUDGET_CHECKS = %i[unfunded ambiguous_funding unplaced budget_variance unused_budget_lines].freeze

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

  def reasons(check) = found.select { it.check == check }.map { [ it.subject_id, it.reason ] }

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

  should "mark a line spent past its amount and head count, saying by how many FTE but never by how much money" do
    platform = line(cost_centre: "Platform", amount: 150_000, head_count: 1)
    2.times { open_position }

    assert_equal [ [ platform, "Spends over its approved amount and over its head count by 1 FTE" ] ], reasons(:budget_variance)
    assert_no_match(/\d{3}/, reasons(:budget_variance).sole.last)
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
