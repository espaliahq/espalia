# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanScopeTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 1, 1)

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments, teams = Array.new(2) { SecureRandom.uuid_v7 }
    @engineering, @payments, @sales = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @family = create(:framework_role_family, name: "Engineering")
      @engineer = create(:framework_role, code: "E", name: "Software Engineer", role_family_id: @family.role_family_id)
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")

      structure.define_taxonomy([ { level_id: @departments, name: "Department" }, { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: @departments, effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, parent_id: @engineering, effective_on: "2025-01-01")
      structure.create_unit(@sales, "Sales", level_id: @departments, effective_on: "2025-01-01")

      @ada, @brook, @cy, @dee = %w[Ada Brook Cy Dee].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      [ @ada, @brook, @cy, @dee ].each do |person|
        people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
      end
      people.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      people.set_membership(@brook.id, @payments, **ESPALIA, allocation: 0.5)
      people.set_membership(@brook.id, @sales, **ESPALIA, allocation: 0.5)
      people.set_membership(@cy.id, @sales, **ESPALIA, allocation: 1.0)
      people.set_membership(@dee.id, @sales, **ESPALIA, allocation: 1.0)
      people.change_manager(@ada.id, @cy.id, **ESPALIA)

      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "EUR")

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id, @whole_id = Array.new(2) { SecureRandom.uuid_v7 }
      handler.create_plan(@plan_id, name: "Engineering next year", base_on: BASE_ON, unit_ids: [ @engineering ])
      handler.create_plan(@whole_id, name: "Everyone next year", base_on: BASE_ON)
      [ @plan_id, @whole_id ].each do |plan_id|
        handler.set_change(plan_id, TeamPlanning::Events::RuleSet, scenario_id: plan_id, subject_id: plan_id,
                                                                   end_state: { rule: "capacity_model", value: { families: { @family.role_family_id => { model: "per_fte" } }, roles: {} } })
      end
    end
    @h1 = fork(@plan_id, name: "H1", ends_on: "2026-06-30")
    @h2 = fork(@plan_id, parent_id: @h1, name: "H2", ends_on: "2026-12-31")
    @whole_h1 = fork(@whole_id, name: "H1", ends_on: "2026-06-30")
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context)

  def call(operation, **params) = as_tenant { operation.call(context:, params: params.compact) }

  def fork(plan_id, parent_id: nil, **params)
    call(Operations::TeamPlanning::ForkScenario, plan_id:, parent_id:, relation: "then", **params)[:scenario_id]
  end

  def resolve(plan_id, scenario_id)
    as_tenant { TeamPlanning::Resolution.new(context:, plan: TeamPlanningPlan.find(plan_id), scenario_id:).call }
  end

  def cost(plan_id, scenario_id) = call(Operations::TeamPlanning::Cost, plan_id:, scenario_id:)

  def capacity(plan_id, scenario_id) = call(Operations::TeamPlanning::Capacity, plan_id:, scenario_id:)

  def scenario_map(plan_id, scenario_id) = call(Operations::TeamPlanning::ScenarioMap, plan_id:, scenario_id:)

  # A plan no longer places a position outside its scope, so this stands in
  # for one placed before the plan narrowed.
  def sales_seat(scenario_id)
    position_id = SecureRandom.uuid_v7
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::PositionSet, scenario_id:, subject_id: position_id,
                                                                      end_state: { role_id: @engineer.role_id, level_id: @e5.level_id, unit_id: @sales, fte: 1, basis: "new" })
    end
    position_id
  end

  UNIT_OUTSIDE = "This unit is outside the units this plan covers. Place it in one of its units first."
  POSITION_OUTSIDE = "This position is outside the units this plan covers. Place it in one of its units first."

  LINE_OUTSIDE = "This budget line is outside the cost centres this plan covers. Widen the plan's units first."
  NO_SUCH_LINE = "This scenario has no such budget line"

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  def set_scope(plan_id, unit_ids) = call(Operations::TeamPlanning::SetPlanScope, plan_id:, unit_ids:)

  def uncovered(scenario_id)
    call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id:)[:items].select { it[:reason] == TeamPlanning::Attention::UNCOVERED }
  end

  def scope_of(plan_id) = as_tenant { TeamPlanningPlan.find(plan_id).scope_unit_ids.to_a }

  def person(payload, person) = payload[:people].find { it[:id] == person.id }

  # The picker that widens a plan names every unit by design, and no person.
  def plan_reads
    Operations::Registry.all.select do |operation|
      operation.name.start_with?("Operations::TeamPlanning::") && operation.category == :read &&
        operation != Operations::TeamPlanning::CoverableUnits &&
        operation.parameters.values.select(&:required).map(&:name).difference(%i[plan_id scenario_id]).empty?
    end
  end

  def every_read(plan_id, scenario_id)
    plan_reads.to_h do |operation|
      given = { plan_id:, scenario_id: }.slice(*operation.parameters.keys)
      [ operation.name, begin
        call(operation, **given)
      rescue Operations::Base::ParameterError => refusal
        refusal.message
      end ]
    end.to_json
  end

  should "keep a capacity override on a place outside the plan out of the scenario map and what needs attention" do
    [ @payments, @sales ].each do |unit_id|
      call(Operations::TeamPlanning::SetCapacityOverride, plan_id: @plan_id, scenario_id: @h1, person_id: @brook.id, unit_id:, amount: "0.4")
    end

    overrides = person(scenario_map(@plan_id, @h1), @brook)[:capacity_overrides]
    assert_equal [ @payments ], overrides.keys.map(&:to_s)
    assert_not_includes scenario_map(@plan_id, @h1).to_json, @sales

    call(Operations::TeamPlanning::SetCapacityOverride, plan_id: @plan_id, scenario_id: @h1, person_id: @ada.id, unit_id: @sales, amount: "0.4")
    assert_not_includes call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @h1).to_json, @sales
  end

  should "keep an override on a closed position outside the scope out of what needs attention" do
    position = sales_seat(@h1)
    as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::PositionClosed, scenario_id: @h2, subject_id: position, end_state: {}) }
    call(Operations::TeamPlanning::SetCapacityOverride, plan_id: @plan_id, scenario_id: @h2, person_id: @ada.id, position_id: position, amount: "0.4")

    assert_not_includes call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @h2).to_json, position
  end

  should "count a person half in the plan when half their time is in units it covers, in every total" do
    map = resolve(@plan_id, @h1)
    assert_equal [ @ada.id, @brook.id ], map.people.map(&:id).sort_by { [ @ada.id, @brook.id ].index(it) }
    assert_equal [ @cy.id, @dee.id ].sort, map.outside.map(&:id).sort

    priced = cost(@plan_id, @h1)
    total = priced[:total][:scenario][:converted].to_r
    everyone = cost(@whole_id, @whole_h1)[:total][:scenario][:converted].to_r
    assert_in_delta 1.5r / 4, total / everyone, 1e-12, "Ada and half of Brook, of the four people a whole-organisation plan counts"
    assert_equal total, priced[:units].sum { it[:scenario][:converted].to_r }, "the units add up to the plan's total"

    delivered = capacity(@plan_id, @h1)
    assert_equal({ "per_fte" => 1.5 }, delivered[:totals].transform_values(&:to_f))
    assert_equal [ [ @payments, 1.5 ] ], delivered[:units].map { [ it[:unit_id], it[:totals]["per_fte"].to_f ] }

    brook = person(scenario_map(@plan_id, @h1), @brook)
    assert_equal [ @payments ], brook[:memberships].map { it[:unit_id] }
    assert_equal({ share: 0.5 }, brook[:outside])
  end

  should "read a plan covering the whole organisation exactly as before scope existed" do
    map = resolve(@whole_id, @whole_h1)
    assert_nil map.scope_ids
    assert_empty map.outside

    payload = scenario_map(@whole_id, @whole_h1)
    assert_equal [ @payments, @sales ].sort, person(payload, @brook)[:memberships].map { it[:unit_id] }.sort
    payload[:people].each { assert_not it.key?(:outside) || it.key?(:manager_outside) }
    assert_equal @cy.id, person(payload, @ada)[:manager_id]
    assert_equal({ "per_fte" => 4.0 }, capacity(@whole_id, @whole_h1)[:totals].transform_values(&:to_f))
  end

  should "never let a unit or person outside the scope reach a plan read, though a whole-organisation plan shows them" do
    as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).set_membership(@brook.id, @payments, **ESPALIA, allocation: 0.7) }
    leaked = [ @sales, @cy.id, @dee.id ]
    scoped = every_read(@plan_id, @h1)
    leaked.each { assert_not_includes scoped, it }

    whole = every_read(@whole_id, @whole_h1)
    leaked.each { assert_includes whole, it, "the control proves the reads would carry it" }
    assert person(scenario_map(@plan_id, @h1), @ada)[:manager_outside]
  end

  # Platform is Ada's own; Core and Engineers come from entries a seat in
  # Engineering can match; Field Sales and Revenue belong to Sales alone.
  def budget_by_cost_centre
    as_tenant do
      OrgGraph::CommandHandler.new(actor: SYSTEM).change_cost_centre(@ada.id, "Platform", **ESPALIA)
      OrgGraph::CommandHandler.new(actor: SYSTEM).change_cost_centre(@cy.id, "Field Sales", **ESPALIA)
      call(Operations::Tenants::SetPlanningRule, rule: "cost_centre",
                                                 value: { entries: [ { unit_id: @engineering, cost_centre: "Core" }, { unit_id: @sales, cost_centre: "Revenue" },
                                                                     { role_id: @engineer.role_id, cost_centre: "Engineers" } ] })
      [ "Platform", "Core", "Engineers", nil, "Field Sales", "Revenue" ].to_h do |cost_centre|
        [ cost_centre, BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 777_123, currency: "EUR", period: "year",
                                          cost_centre:).id ]
      end
    end
  end

  context "budget lines" do
    setup { @lines = budget_by_cost_centre }

    should "hold only the lines naming a cost centre its seats can draw on, or none, and hide the rest" do
      map = resolve(@plan_id, @h1)
      assert_equal @lines.values_at("Platform", "Core", "Engineers", nil).sort, map.budget_lines.map(&:id).sort
      assert_equal @lines.values_at("Field Sales", "Revenue").sort, map.outside_lines.map(&:id).sort
      assert_equal @lines.values.sort, resolve(@whole_id, @whole_h1).budget_lines.map(&:id).sort
    end

    should "keep an entry on a unit above the scope, since a seat inside it matches" do
      set_scope(@plan_id, [ @payments ])
      assert_includes resolve(@plan_id, @h1).budget_lines.map(&:id), @lines["Core"]
    end

    should "never let a line outside the plan's cost centres reach a plan read, nor count it, though a whole-organisation plan does" do
      leaked = [ *@lines.values_at("Field Sales", "Revenue"), "Field Sales", "Revenue" ]
      scoped = every_read(@plan_id, @h1)
      leaked.each { assert_not_includes scoped, it }
      assert_equal 4, call(Operations::TeamPlanning::BudgetLines, plan_id: @plan_id, scenario_id: @h1)[:budget_lines].size

      whole = every_read(@whole_id, @whole_h1)
      leaked.each { assert_includes whole, it, "the control proves the reads would carry it" }
    end

    should "keep a change or cut a plan made to a hidden line hidden, never reading it as orphaned" do
      as_tenant do
        handler.set_change(@plan_id, TeamPlanning::Events::BudgetLineSet, scenario_id: @h1, subject_id: @lines["Field Sales"],
                                                                          end_state: { starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 9,
                                                                                       currency: "EUR", period: "year", cost_centre: "Field Sales", tenant_line: true })
        handler.set_change(@plan_id, TeamPlanning::Events::BudgetLineCut, scenario_id: @h1, subject_id: @lines["Revenue"], end_state: { tenant_line: true })
      end
      map = resolve(@plan_id, @h1)
      assert_equal @lines.values_at("Field Sales", "Revenue").sort, map.outside_lines.map(&:id).sort, "a cut outside line stays outside"
      assert_empty map.orphaned_lines
      # The plan's own record of a change keeps it, as it keeps one about someone the Org Graph moved out.
      record = %w[History Overrides Status SplitNeeds].map { "Operations::TeamPlanning::#{it}" }
      scoped = JSON.parse(every_read(@plan_id, @h1)).except(*record).to_json
      [ *@lines.values_at("Field Sales", "Revenue"), "Field Sales" ].each { assert_not_includes scoped, it }

      as_tenant { BudgetLine.find(@lines["Field Sales"]).destroy! }
      assert_empty resolve(@plan_id, @h1).orphaned_lines, "a removed line the plan never held stays unnamed"
    end

    should "refuse to set again a hidden line a scenario cut, whatever cost centre it names" do
      as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::BudgetLineCut, scenario_id: @h1, subject_id: @lines["Revenue"], end_state: { tenant_line: true }) }
      line = { plan_id: @plan_id, scenario_id: @h1, starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: "5", currency: "EUR", period: "year" }
      assert_equal NO_SUCH_LINE, refusal { call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: @lines["Revenue"], cost_centre: "Platform") }
    end

    should "leave a line outside the plan's cost centres out of the budget checks, which judge only the lines the plan holds" do
      checks = %w[unused_budget_lines budget_variance]
      items = ->(plan_id, scenario_id) { call(Operations::TeamPlanning::Attention, plan_id:, scenario_id:)[:items].select { it[:check].in?(checks) } }
      held_names = [ "Platform", "Core", "Engineers", TeamPlanning::Attention::NO_COST_CENTRE ]

      scoped = items.(@plan_id, @h1)
      assert_equal @lines.values_at("Platform", "Core", "Engineers", nil).sort, scoped.select { it[:facet] == TeamPlanning::Attention::BUDGET_LINE }.map { it[:subject_id] }.sort,
                   "every held line is unused, and no other"
      assert_empty scoped.reject { it[:facet] == TeamPlanning::Attention::BUDGET_LINE || it[:subject_id].in?([ @plan_id, *held_names ]) }
      cost_centres = call(Operations::TeamPlanning::Budget, plan_id: @plan_id, scenario_id: @h1)[:cost_centres].map { it[:cost_centre] }
      assert_empty cost_centres - [ "Platform", "Core", "Engineers", nil ], "the no-cost-centre group sits beside held cost centres only"

      whole = items.(@whole_id, @whole_h1).map { it[:subject_id] }
      @lines.values_at("Field Sales", "Revenue").each { assert_includes whole, it, "the control proves the check would name it" }
    end

    should "read an archived scoped plan from its frozen lines, cut to its cost centres, though it was archived before its base date" do
      as_tenant { handler.archive_plan(@plan_id) }
      plan = TeamPlanningPlan.find(@plan_id)
      assert_operator plan.archived_on, :<, plan.base_on - 1, "known_on is the archive day, not the day before the base"

      leaked = [ *@lines.values_at("Field Sales", "Revenue"), "Field Sales", "Revenue" ]
      reads = [ Operations::TeamPlanning::Budget, Operations::TeamPlanning::BudgetLines, Operations::TeamPlanning::Funding, Operations::TeamPlanning::Attention ]
                .map { call(it, plan_id: @plan_id, scenario_id: @h1) }
      assert_equal @lines.values_at("Platform", "Core", "Engineers", nil).sort, reads.first[:budget_lines].map { it[:budget_line_id] }.sort
      leaked.each { assert_not_includes reads.to_json, it }
    end

    should "judge the lines by the baseline's cost centres on any day, not that day's" do
      travel_to Time.utc(2026, 2, 1, 9)
      as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).change_cost_centre(@ada.id, "Field Sales", provider: "espalia", effective_on: Date.current.iso8601) }
      baseline = TeamPlanning::Baseline.new(context:, plan: TeamPlanningPlan.find(@plan_id))
      today = as_tenant { baseline.map_on(Date.current) }
      assert_equal as_tenant { baseline.structure.held_cost_centres }, today.held_cost_centres
      assert_includes today.budget_lines.map(&:id), @lines["Platform"]
      assert_includes today.outside_lines.map(&:id), @lines["Field Sales"]
    end

    should "refuse to change, cut, add or draw on a line outside the plan's cost centres, without naming it" do
      line = { plan_id: @plan_id, scenario_id: @h1, starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: "5", currency: "EUR", period: "year" }
      seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @h1, role_id: @engineer.role_id,
                                                         level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new")[:position_id]
      unknown = [
        -> { call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: @lines["Field Sales"], cost_centre: "Field Sales") },
        -> { call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: @lines["Field Sales"], cost_centre: "Platform") },
        -> { call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id: @h1, budget_line_id: @lines["Revenue"]) },
        -> { call(Operations::TeamPlanning::SetPositionFunding, plan_id: @plan_id, scenario_id: @h1, position_id: seat, draws: [ { budget_line_id: @lines["Revenue"] } ]) }
      ]
      unknown.each { assert_equal NO_SUCH_LINE, refusal(&it) }
      named = [
        -> { call(Operations::TeamPlanning::SetBudgetLine, **line, cost_centre: "Revenue") },
        -> { call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: @lines["Platform"], cost_centre: "Field Sales") }
      ]
      named.each { assert_equal LINE_OUTSIDE, refusal(&it), "a cost centre the caller gave says nothing about which lines exist" }
      assert_empty TeamPlanning::Repository.new.then { |repository| as_tenant { repository.load_plan(@plan_id) } }.changes_in(@h1).select { it.data[:subject_id].in?(@lines.values) }

      call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: @lines["Platform"], cost_centre: "Core")
      call(Operations::TeamPlanning::SetBudgetLine, **line, cost_centre: nil)
      call(Operations::TeamPlanning::SetPositionFunding, plan_id: @plan_id, scenario_id: @h1, position_id: seat, draws: [ { budget_line_id: @lines["Engineers"] } ])
      call(Operations::TeamPlanning::CutBudgetLine, plan_id: @whole_id, scenario_id: @whole_h1, budget_line_id: @lines["Revenue"])
    end

    should "refuse a write on a line outside the plan exactly as on an id no line has, so a write can't confirm it exists" do
      line = { plan_id: @plan_id, scenario_id: @h1, starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: "5", currency: "EUR", period: "year" }
      seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @h1, role_id: @engineer.role_id,
                                                         level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new")[:position_id]
      as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::BudgetLineCut, scenario_id: @h1, subject_id: @lines["Revenue"], end_state: { tenant_line: true }) }
      gone_level = SecureRandom.uuid_v7
      as_tenant { BudgetLine.where(id: @lines.values_at("Field Sales", "Revenue")).update_all(level_id: gone_level) }
      writes = {
        set: ->(id) { call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: id, cost_centre: "Platform") },
        set_kept_level: ->(id) { call(Operations::TeamPlanning::SetBudgetLine, **line, budget_line_id: id, level_id: gone_level) },
        cut: ->(id) { call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id: @h1, budget_line_id: id) },
        fund: ->(id) { call(Operations::TeamPlanning::SetPositionFunding, plan_id: @plan_id, scenario_id: @h1, position_id: seat, draws: [ { budget_line_id: id } ]) }
      }
      unknown = SecureRandom.uuid_v7
      writes.each do |name, write|
        expected = refusal { write.(unknown) }
        @lines.values_at("Field Sales", "Revenue").each { |id| assert_equal expected, refusal { write.(id) }, "#{name} told an outside line from an unknown id" }
      end
    end

    should "refuse to narrow the scope while a change touches a line the narrower plan would drop, without naming it" do
      set_scope(@plan_id, [ @engineering, @sales ])
      call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id: @h1, budget_line_id: @lines["Revenue"])

      message = refusal { set_scope(@plan_id, [ @engineering ]) }
      assert_includes message, "1 other change"
      [ @lines["Revenue"], "Revenue" ].each { assert_not_includes message, it }

      call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1)
      set_scope(@plan_id, [ @engineering ])
      assert_includes resolve(@plan_id, @h1).outside_lines.map(&:id), @lines["Revenue"]
    end

    should "judge a dropped line by each scenario's own cost centre, so another scenario's relabel never excuses a cut" do
      set_scope(@plan_id, [ @engineering, @sales ])
      sibling = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @h1, relation: "instead", name: "B")[:scenario_id]
      call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id: @h1, budget_line_id: @lines["Revenue"])
      call(Operations::TeamPlanning::SetBudgetLine, plan_id: @plan_id, scenario_id: sibling, budget_line_id: @lines["Revenue"], cost_centre: "Platform",
                                                   starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: "5", currency: "EUR", period: "year")

      assert_includes refusal { set_scope(@plan_id, [ @engineering ]) }, "1 other change"
    end

    should "leave no funding naming a line outside the plan, though an older change funded a seat from it or cut it" do
      seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @h1, role_id: @engineer.role_id,
                                                         level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new")[:position_id]
      fund = -> { handler.set_change(@plan_id, TeamPlanning::Events::PositionFundingSet, scenario_id: @h1, subject_id: seat,
                                                                                          end_state: { draws: [ { budget_line_id: @lines["Revenue"] } ] }) }
      reads = lambda do
        [ resolve(@plan_id, @h1).fundings, %w[Funding Attention].map { call("Operations::TeamPlanning::#{it}".constantize, plan_id: @plan_id, scenario_id: @h1) } ].to_json
      end

      as_tenant { fund.() }
      assert_not_includes reads.(), @lines["Revenue"], "a funding on an outside line"
      as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::BudgetLineCut, scenario_id: @h1, subject_id: @lines["Revenue"], end_state: { tenant_line: true }) }
      assert_not_includes reads.(), @lines["Revenue"], "a funding on an outside line the scenario then cut"
      assert_empty resolve(@plan_id, @h1).orphaned_lines
    end
  end

  should "bring a person in with the change that places them in scope, and let them go when it's undone" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    assert_includes resolve(@plan_id, @h1).people.map(&:id), @dee.id

    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1)
    map = resolve(@plan_id, @h1)
    assert_not_includes map.people.map(&:id), @dee.id
    assert_includes map.outside.map(&:id), @dee.id
  end

  should "refuse a change about someone outside the scope unless it places them in a covered unit" do
    refusals = [
      -> { call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, level: "6") },
      -> { call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, leaves_on: "2026-05-01") },
      -> { call(Operations::TeamPlanning::SetReportingLine, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, manager_id: @ada.id) },
      lambda {
        call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id,
                                                      placements: [ { unit_id: @sales, allocation: 1 } ])
      }
    ]
    refusals.each do |write|
      error = assert_raises(Operations::Base::ParameterError) { write.call }
      assert_equal "This person is outside the units this plan covers. Place them in one of its units first.", error.message
    end

    call(Operations::TeamPlanning::SetReportingLine, plan_id: @plan_id, scenario_id: @h1, person_id: @ada.id, manager_id: @dee.id)
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @whole_id, scenario_id: @whole_h1, person_id: @dee.id, level: "6")
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, level: "6")
    assert_includes resolve(@plan_id, @h1).people.map(&:id), @dee.id
  end

  should "refuse to redo a change about someone a narrower plan no longer covers, unless it places them in" do
    set_scope(@plan_id, [ @engineering, @sales ])
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, level: "6")
    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h2, person_id: @cy.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h2)
    set_scope(@plan_id, [ @engineering ])

    error = assert_raises(Operations::Base::ParameterError) { call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @h1) }
    assert_equal "This person is outside the units this plan covers. Place them in one of its units first.", error.message
    assert_not_includes resolve(@plan_id, @h1).people.map(&:id), @dee.id

    call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @h2)
    assert_includes resolve(@plan_id, @h2).people.map(&:id), @cy.id
  end

  should "refuse to move a change earlier into a step where the person it is about is still outside the scope" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h2, person_id: @dee.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: @h2, person_id: @dee.id)

    error = assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::MoveChange, plan_id: @plan_id, scenario_id: @h2, subject_id: @dee.id, facet: "departure", direction: "earlier")
    end
    assert_equal "This person is outside the units this plan covers. Place them in one of its units first.", error.message
    assert_empty as_tenant { TeamPlanning::Repository.new.load_plan(@plan_id) }.changes_in(@h1)
  end

  should "refuse to undo a clear that would bring back a change about someone a narrower plan no longer covers" do
    set_scope(@plan_id, [ @engineering, @sales ])
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, level: "6")
    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @h1, subject_id: @dee.id, facet: "level")
    set_scope(@plan_id, [ @engineering ])

    error = assert_raises(Operations::Base::ParameterError) { call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1) }
    assert_equal "This person is outside the units this plan covers. Place them in one of its units first.", error.message
    assert_empty uncovered(@h1)
  end

  should "refuse to place a unit or position outside the scope, or to change one the plan doesn't cover" do
    teams = resolve(@plan_id, @h1).units.find { it.id == @payments }.level_id
    assert_equal POSITION_OUTSIDE, refusal { call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @h1, role_id: @engineer.role_id,
                                                                                         level_id: @e5.level_id, unit_id: @sales, fte: 1, basis: "new") }
    assert_equal UNIT_OUTSIDE, refusal { call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, name: "Labs", top_level: true, level_id: @departments) }
    assert_equal UNIT_OUTSIDE, refusal { call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, unit_id: @payments, top_level: true) }

    call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, name: "Platform", parent_id: @engineering, level_id: teams)
    seat = sales_seat(@h1)
    assert_equal POSITION_OUTSIDE, refusal { call(Operations::TeamPlanning::ClosePosition, plan_id: @plan_id, scenario_id: @h1, position_id: seat) }
    assert_empty uncovered(@h1)
  end

  should "refuse to redo a move that took a unit the scenario created out of a narrower plan" do
    set_scope(@plan_id, [ @engineering, @sales ])
    teams = resolve(@plan_id, @h1).units.find { it.id == @payments }.level_id
    platform = call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, name: "Platform", parent_id: @engineering, level_id: teams)[:unit_id]
    call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, unit_id: platform, parent_id: @sales)
    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1)
    set_scope(@plan_id, [ @engineering ])

    assert_equal UNIT_OUTSIDE, refusal { call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @h1) }
    assert_includes resolve(@plan_id, @h1).units.map(&:id), platform
  end

  should "refuse to undo a funding clear on a closed position a narrower plan no longer covers" do
    set_scope(@plan_id, [ @engineering, @sales ])
    line_id = SecureRandom.uuid_v7
    seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @h1, role_id: @engineer.role_id,
                                                       level_id: @e5.level_id, unit_id: @sales, fte: 1, basis: "new")[:position_id]
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::PositionFundingSet, scenario_id: @h1, subject_id: seat,
                                                                             end_state: { draws: [ { budget_line_id: line_id, share: "1" } ] })
    end
    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @h1, subject_id: seat, facet: "funding")
    call(Operations::TeamPlanning::ClosePosition, plan_id: @plan_id, scenario_id: @h1, position_id: seat)
    set_scope(@plan_id, [ @engineering ])
    cleared = call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @h1)[:entries].find { it[:facet] == "funding" && it[:action] == "clear" }

    assert_equal POSITION_OUTSIDE, refusal { call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1, event_id: cleared[:event_id]) }
  end

  should "refuse to redo a succession that names a unit a narrower plan no longer covers" do
    set_scope(@plan_id, [ @engineering, @sales ])
    call(Operations::TeamPlanning::SetUnitSuccession, plan_id: @plan_id, scenario_id: @h1, predecessor_ids: [ @payments ], successor_ids: [ @sales ])
    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1)
    set_scope(@plan_id, [ @engineering ])

    assert_equal UNIT_OUTSIDE, refusal { call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @h1) }
    assert_empty resolve(@plan_id, @h1).successions
  end

  should "refuse to undo a clear that would bring back a position a narrower plan no longer covers" do
    set_scope(@plan_id, [ @engineering, @sales ])
    seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @h1, role_id: @engineer.role_id,
                                                       level_id: @e5.level_id, unit_id: @sales, fte: 1, basis: "new")[:position_id]
    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @h1, subject_id: seat, facet: "position")
    set_scope(@plan_id, [ @engineering ])

    assert_equal POSITION_OUTSIDE, refusal { call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1) }
    assert_empty uncovered(@h1)
  end

  should "refuse to undo a move back in when the move it brings back takes a unit out of a narrower plan" do
    set_scope(@plan_id, [ @engineering, @sales ])
    call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, unit_id: @payments, parent_id: @sales)
    call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @h1, unit_id: @payments, parent_id: @engineering)
    set_scope(@plan_id, [ @engineering ])

    assert_equal UNIT_OUTSIDE, refusal { call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1) }
    assert_includes resolve(@plan_id, @h1).units.map(&:id), @payments
  end

  should "flag a change about someone the plan no longer covers, whether a bring-in was undone or the Org Graph moved them out" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @h1, person_id: @dee.id, level: "6")
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @h1, person_id: @ada.id, level: "6")
    assert_empty uncovered(@h1)

    bring_in = call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @h1)[:entries]
               .find { it[:subject_id] == @dee.id && it[:facet] == "assignment" }[:event_id]
    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @h1, event_id: bring_in)
    assert_equal [ [ @dee.id, "level", "LevelSet" ] ], uncovered(@h1).map { [ it[:subject_id], it[:facet], it[:change][:kind] ] }

    as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).move_membership(@ada.id, @payments, @sales, effective_on: "2025-12-20") }
    attention = call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @h1)
    assert_equal [ @ada.id, @dee.id ].sort, attention[:items].select { it[:reason] == TeamPlanning::Attention::UNCOVERED }.map { it[:subject_id] }.sort
    assert_not_includes attention[:names].keys, @dee.id
    assert_not_includes attention[:names].keys, @ada.id
  end

  should "leave a planned move out of the scope unflagged" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @ada.id,
                                                  placements: [ { unit_id: @sales, allocation: 1 } ])
    assert_empty uncovered(@h1)
  end

  should "show leaving the plan and joining it as moves on the timeline" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h2, person_id: @ada.id,
                                                  placements: [ { unit_id: @sales, allocation: 1 } ])
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h2, person_id: @dee.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    moves = call(Operations::TeamPlanning::Timeline, plan_id: @plan_id, scenario_id: @h2)[:lanes].flat_map { it[:moves] }

    ada = moves.find { it[:person_id] == @ada.id }
    assert_equal [ "out", [ @payments ], [] ], ada.values_at(:crossing, :left_unit_ids, :joined_unit_ids)
    dee = moves.find { it[:person_id] == @dee.id }
    assert_equal [ "in", [], [ @payments ] ], dee.values_at(:crossing, :left_unit_ids, :joined_unit_ids)
  end

  should "leave a position in a unit outside the scope off the map and out of its totals" do
    position = sales_seat(@h1)
    assert_not_includes resolve(@plan_id, @h1).positions.map(&:id), position
    assert_equal({ "per_fte" => 1.5 }, capacity(@plan_id, @h1)[:totals].transform_values(&:to_f))
  end

  should "keep a funding on a position outside the scope out of what needs attention" do
    line = as_tenant { BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", head_count: 1) }
    position = sales_seat(@h1)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::PositionFundingSet, scenario_id: @h1, subject_id: position,
                                                                             end_state: { draws: [ { budget_line_id: line.id } ] })
    end

    assert_not_includes call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @h2).to_json, position
  end

  should "count someone who left in an earlier step as gone when a later step brings them in" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @cy.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: @h1, person_id: @cy.id)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h2, person_id: @cy.id,
                                                  placements: [ { unit_id: @payments, allocation: 1 } ])
    map = resolve(@plan_id, @h2)
    assert_not_includes map.people.map(&:id), @cy.id
    assert_includes map.departed.map(&:person_id), @cy.id
  end

  should "read a change as done once the Org Graph moves its person out of the scope as planned" do
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @plan_id, person_id: @ada.id,
                                                  placements: [ { unit_id: @sales, allocation: 1 } ])
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      OrgGraph::CommandHandler.new(actor: SYSTEM).move_membership(@ada.id, @payments, @sales, effective_on: "2026-02-01")
    end

    statuses = call(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: @plan_id)[:statuses]
    assert_equal "done", statuses.find { it[:subject_id] == @ada.id && it[:facet] == "assignment" }[:status].to_s
  end

  should "mask a manager seat or a backfill outside the scope, as it masks a manager outside" do
    outside_seat = sales_seat(@h1)
    [ @plan_id, @whole_id ].zip([ @h1, @whole_h1 ]).each do |plan_id, scenario_id|
      seat = plan_id == @plan_id ? outside_seat : call(Operations::TeamPlanning::SetPosition, plan_id:, scenario_id:, role_id: @engineer.role_id,
                                                                                         level_id: @e5.level_id, unit_id: @sales, fte: 1, basis: "new")[:position_id]
      call(Operations::TeamPlanning::SetReportingLine, plan_id:, scenario_id:, person_id: @ada.id, manager_position_id: seat)
    end

    ada = person(scenario_map(@plan_id, @h1), @ada)
    assert_nil ada[:manager_position_id]
    assert ada[:manager_outside]
    assert_not_includes scenario_map(@plan_id, @h1).to_json, outside_seat
    assert person(scenario_map(@whole_id, @whole_h1), @ada)[:manager_position_id], "the control proves the payload would carry it"

    attention = call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @h1)
    assert_empty attention[:items].select { it[:subject_id] == @ada.id && it[:facet] == "reporting_line" }
    assert_not_includes attention.to_json, outside_seat
  end

  should "keep a place in a position outside the scope outside, however often the map settles, and read it as done once it shows" do
    outside_seat = sales_seat(@plan_id)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @plan_id, person_id: @brook.id,
                                                  placements: [ { unit_id: @payments, allocation: 0.5 }, { position_id: outside_seat, allocation: 0.5 } ])

    map = resolve(@plan_id, @plan_id)
    brook = map.people.find { it.id == @brook.id }
    resettled = map.settled.people.find { it.id == @brook.id }
    assert_equal [ @sales ], map.outside_places(brook).map(&:unit_id)
    assert_equal map.outside_places(brook), map.outside_places(resettled)

    statuses = call(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: @plan_id)[:statuses]
    assert_equal "done", statuses.find { it[:subject_id] == @brook.id && it[:facet] == "assignment" }[:status].to_s
  end

  should "keep a place outside the plan as it was when a move changes one inside, and refuse one with nothing left to keep" do
    eve = as_tenant do
      create(:person, tenant: @tenant, name: "Eve Quill").tap do |person|
        people = OrgGraph::CommandHandler.new(actor: SYSTEM)
        people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
        people.set_membership(person.id, @payments, **ESPALIA, allocation: 1.0)
        people.set_membership(person.id, @sales, **ESPALIA)
      end
    end
    move = ->(who) { call(Operations::TeamPlanning::MovePlace, plan_id: @plan_id, scenario_id: @h1, person_id: who.id, from_unit_id: @payments, to_unit_id: @engineering, allocation: 0.5) }

    move.(@brook)
    brook = resolve(@plan_id, @h1).people.find { it.id == @brook.id }
    assert_equal [ [ @sales, 0.5 ], [ @engineering, 0.5 ] ], brook.memberships.map { [ it.unit_id, it.allocation.to_f ] }

    error = assert_raises(Operations::Base::ParameterError) { move.(eve) }
    assert_match "in units this plan doesn't cover", error.message
    assert_not_includes error.message, "Sales"
  end

  context "changing the scope" do
    should "refuse a unit id written without its hyphens, so the ids a plan keeps compare as written" do
      error = assert_raises(Operations::Base::ParameterError) { set_scope(@plan_id, [ @engineering, @sales.delete("-") ]) }
      assert_equal "A plan covers units the organisation has", error.message
      assert_equal [ @engineering ], scope_of(@plan_id)
    end

    should "always let a plan widen, and narrow while nothing it plans falls outside" do
      assert_equal [ "Engineering", "Sales" ], set_scope(@plan_id, [ @engineering, @sales ])[:scope][:units].map { it[:name] }.sort
      assert_equal({ whole_organisation: true, units: [] }, set_scope(@plan_id, [])[:scope])

      call(Operations::TeamPlanning::SetAssignment, plan_id: @whole_id, scenario_id: @whole_h1, person_id: @ada.id,
                                                    placements: [ { unit_id: @payments, allocation: 0.5 } ])
      set_scope(@whole_id, [ @engineering ])
      assert_equal [ @engineering ], scope_of(@whole_id)
    end

    should "refuse to narrow while a change is about something left out, naming what it can and counting the rest" do
      [ @cy, @dee ].each do |person|
        call(Operations::TeamPlanning::SetAssignment, plan_id: @whole_id, scenario_id: @whole_h1, person_id: person.id,
                                                      placements: [ { unit_id: @sales, allocation: 0.5 } ])
      end

      error = assert_raises(Operations::Base::ParameterError) { set_scope(@whole_id, [ @engineering ]) }
      assert_equal "The narrower plan would leave out what these changes are about: Cy Quill in H1 and Dee Quill in H1. " \
                   "Undo them, or keep the units they are about", error.message
      assert_empty scope_of(@whole_id), "the scope stands as it was"

      Operations::TeamPlanning::SetPlanScope.stub(:named, 1) do
        error = assert_raises(Operations::Base::ParameterError) { set_scope(@whole_id, [ @engineering ]) }
        assert_match "Cy Quill in H1 and 1 other change.", error.message
      end
    end

    should "let a plan re-cover the same units though a change already moves someone outside them" do
      call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @h1, person_id: @ada.id,
                                                    placements: [ { unit_id: @sales, allocation: 1 } ])
      set_scope(@plan_id, [ @payments ])
      assert_equal [ @payments ], scope_of(@plan_id)
    end

    should "name a person once and count no other change when two changes are about them" do
      call(Operations::TeamPlanning::SetAssignment, plan_id: @whole_id, scenario_id: @whole_h1, person_id: @cy.id,
                                                    placements: [ { unit_id: @sales, allocation: 0.5 } ])
      call(Operations::TeamPlanning::SetDeparture, plan_id: @whole_id, scenario_id: @whole_h1, person_id: @cy.id)

      error = assert_raises(Operations::Base::ParameterError) { set_scope(@whole_id, [ @engineering ]) }
      assert_match "about: Cy Quill in H1. Undo", error.message
    end

    should "judge each change by its own scenario, so a person brought in elsewhere doesn't excuse it" do
      call(Operations::TeamPlanning::SetAssignment, plan_id: @whole_id, scenario_id: @whole_h1, person_id: @dee.id,
                                                    placements: [ { unit_id: @payments, allocation: 1 } ])
      call(Operations::TeamPlanning::SetDeparture, plan_id: @whole_id, scenario_id: @whole_id, person_id: @dee.id)

      error = assert_raises(Operations::Base::ParameterError) { set_scope(@whole_id, [ @engineering ]) }
      assert_match "Dee Quill in the baseline", error.message
    end

    should "cover only units the organisation still has, but keep one retired since the plan chose it" do
      archive = SecureRandom.uuid_v7
      as_tenant { OrgGraph::StructureCommandHandler.new(actor: SYSTEM).create_unit(archive, "Archive", level_id: @departments, effective_on: "2025-01-01") }
      set_scope(@plan_id, [ @engineering, archive ])
      as_tenant { OrgGraph::StructureCommandHandler.new(actor: SYSTEM).retire_unit(archive, effective_on: "2025-06-01") }

      set_scope(@plan_id, [ @engineering, archive, @sales ])
      assert_equal [ @engineering, archive, @sales ].sort, scope_of(@plan_id).sort
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::CreatePlan, name: "Archive next year", base_on: BASE_ON.iso8601, unit_ids: [ archive ])
      end
      assert_equal "A plan covers units the organisation has", error.message
    end
  end
end
