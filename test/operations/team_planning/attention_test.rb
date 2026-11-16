# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::AttentionTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @department, @squad, @team = Array.new(3) { SecureRandom.uuid_v7 }
    @engineering, @payments, @growth = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @newcomer = create(:person, tenant: @tenant, name: "Nia Newcomer")
      @head = create(:person, tenant: @tenant, name: "Hal Head")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      structure.define_taxonomy([ { level_id: @department, name: "Department" }, { level_id: @squad, name: "Squad" },
                                  { level_id: @team, name: "Team" } ],
                                effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: @department, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      handler.record_person(@head.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed")
      handler.set_membership(@head.id, @engineering, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      structure.add_unit_owner(@engineering, @head.id, effective_on: "2026-02-01")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", fte: 0.8)
      handler.change_manager(@ada.id, @head.id, **ESPALIA, effective_on: "2026-02-01")
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      handler.record_person(@bo.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed")
      handler.set_membership(@bo.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      handler.change_manager(@bo.id, @head.id, **ESPALIA, effective_on: "2026-02-01")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    @q1 = fork(relation: "then", name: "Q1", ends_on: "2026-06-30")
    @q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def write(operation, scenario_id, **params) = call(operation, plan_id: @plan_id, scenario_id:, **params)

  def assign(scenario_id, person, *placements) = write(Operations::TeamPlanning::SetAssignment, scenario_id, person_id: person.id, placements:)

  def open_position(scenario_id, unit_id: @growth)
    write(Operations::TeamPlanning::SetPosition, scenario_id, role_id: @engineer.role_id, level_id: @e2.level_id, unit_id:,
                                                              fte: 1, basis: "new")[:position_id]
  end

  def attention(scenario_id = @q2, as: @editor) = call(Operations::TeamPlanning::Attention, as:, plan_id: @plan_id, scenario_id:)

  def items(scenario_id = @q2) = attention(scenario_id)[:items].map { it.values_at(:subject_id, :facet, :reason) }

  def change_of(subject_id, scenario_id = @q2) = attention(scenario_id)[:items].find { it[:subject_id] == subject_id }[:change]

  should "list each place no capacity model covers once one is chosen, naming the people" do
    assert_empty attention(@q1)[:items]

    write(Operations::TeamPlanning::SetRule, @plan_id, rule: "capacity_model", value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    open_position(@q1)
    result = attention(@q1)

    reason = "Counts for no capacity: the person has no title"
    assert_equal [ [ @ada.id, "capacity:#{@payments}", reason ], [ @bo.id, "capacity:#{@payments}", reason ],
                   [ @head.id, "capacity:#{@engineering}", reason ] ].sort,
                 result[:items].map { it.values_at(:subject_id, :facet, :reason) }.sort
    assert_equal({ @ada.id => "Ada Quill", @bo.id => "Bo Reyes", @head.id => "Hal Head" }, result[:names])
    assert_equal [ "unclassified" ], result[:items].map { it[:check] }.uniq
  end

  should "list unclassified places once a model is chosen, even when no place takes it" do
    write(Operations::TeamPlanning::SetRule, @plan_id, rule: "capacity_model", value: { roles: { @engineer.role_id => { model: "per_fte" } } })

    assert_equal [ @ada.id, @bo.id, @head.id ].sort, attention(@q1)[:items].map { it[:subject_id] }.sort
  end

  def overloading_rule
    write(Operations::TeamPlanning::SetRule, @plan_id, rule: "capacity_model",
                                                       value: { roles: { @engineer.role_id => { model: "units", params: { per_report: { direct: "1" } } } } })
  end

  def overloaded(scenario_id = @q1) = attention(scenario_id)[:items].select { it[:facet] == "capacity" }

  should "mark a manager whose reports cost more than their seat delivers, crediting the line that tipped it, by name" do
    overloading_rule
    seat = open_position(@q1, unit_id: @engineering)
    assign(@q1, @head, { position_id: seat, allocation: 1 })
    write(Operations::TeamPlanning::SetReportingLine, @q1, person_id: @bo.id, manager_id: @head.id)
    result = attention(@q1)

    item = overloaded.sole
    assert_equal [ @head.id, "Managing 2 reports costs 1.4 more than the seat delivers" ], item.values_at(:subject_id, :reason)
    assert_equal "ReportingLineSet", item[:change][:kind]
    assert_equal "Hal Head", result[:names][@head.id]
  end

  should "mark an open manager position as a filled one, so leaving the seat empty never hides the load" do
    overloading_rule
    seat = open_position(@q1, unit_id: @engineering)
    [ @ada, @bo ].each { write(Operations::TeamPlanning::SetReportingLine, @q1, person_id: it.id, manager_position_id: seat) }

    assert_equal [ [ seat, "Managing 2 reports costs 1.4 more than the seat delivers" ] ], overloaded.map { it.values_at(:subject_id, :reason) }
  end

  should "mark no manager overloaded under a model that doesn't price reports" do
    write(Operations::TeamPlanning::SetRule, @plan_id, rule: "capacity_model", value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    seat = open_position(@q1, unit_id: @engineering)
    assign(@q1, @head, { position_id: seat, allocation: 1 })
    write(Operations::TeamPlanning::SetReportingLine, @q1, person_id: @bo.id, manager_id: @head.id)

    assert_empty overloaded
  end

  should "read a scenario that fits as needing nothing" do
    assign(@q2, @ada, { unit_id: @growth, allocation: 1 })

    assert_equal({ plan_id: @plan_id, scenario_id: @q2, checked: true, items: [], names: {} }, attention)
  end

  should "mark a step's changes once an earlier step retires the unit they stand on" do
    assign(@q2, @ada, { unit_id: @growth, allocation: 1 })
    risk = write(Operations::TeamPlanning::SetUnit, @q2, name: "Risk", parent_id: @growth, level_id: @team)[:unit_id]
    write(Operations::TeamPlanning::RetireUnit, @q1, unit_id: @growth)

    assert_equal [ [ @ada.id, "assignment", "Placed in a retired unit" ], [ risk, "unit", "Its parent is a retired unit" ] ], items
    assert_equal({ kind: "AssignmentSet", scenario_id: @q2 }, change_of(@ada.id).except(:event_id))
    assert_equal({ kind: "UnitSet", scenario_id: @q2 }, change_of(risk).except(:event_id))
    assert_equal({ @ada.id => "Ada Quill", risk => "Risk" }, attention[:names])
    assert_empty items(@q1)
  end

  should "name a later step's retirement over the earlier step's placement it broke" do
    assign(@q1, @ada, { unit_id: @growth, allocation: 1 })
    write(Operations::TeamPlanning::RetireUnit, @q2, unit_id: @growth)

    assert_equal({ kind: "UnitRetired", scenario_id: @q2 }, change_of(@ada.id).except(:event_id))
  end

  should "name the retirement for someone no scenario moved" do
    write(Operations::TeamPlanning::RetireUnit, @q1, unit_id: @payments)

    assert_equal [ [ @ada.id, "assignment", "Placed in a retired unit" ], [ @bo.id, "assignment", "Placed in a retired unit" ] ].sort, items(@q1)
    assert_equal({ kind: "UnitRetired", scenario_id: @q1 }, change_of(@bo.id, @q1).except(:event_id))
    assert_match Operations::TeamPlanning::PlanWrite::UUID_RE, change_of(@bo.id, @q1)[:event_id]
  end

  should "mark a placement in a position an earlier step closed, and a position someone overfilled" do
    position = open_position(@q1)
    assign(@q2, @ada, { position_id: position, allocation: 1 })
    assign(@q2, @bo, { position_id: position, allocation: 1 })
    assert_equal [ [ position, "position", "Overfilled by 0.8 FTE" ] ], items
    assert_equal "New position: #{@engineer.name}", attention[:names][position]
    assert_equal({ kind: "AssignmentSet", scenario_id: @q2 }, change_of(position).except(:event_id))

    write(Operations::TeamPlanning::ClosePosition, @q1, position_id: position)
    assert_equal [ [ @ada.id, "assignment", "Placed in a closed position" ], [ @bo.id, "assignment", "Placed in a closed position" ] ].sort, items
  end

  should "mark a position in a unit an earlier step retired" do
    position = open_position(@q2)
    write(Operations::TeamPlanning::RetireUnit, @q1, unit_id: @growth)

    assert_equal [ [ position, "position", "In a retired unit" ] ], items
    assert_equal "PositionSet", change_of(position)[:kind]
  end

  should "mark someone placed who isn't on the map" do
    assign(@q2, @newcomer, { unit_id: @growth, allocation: 1 })

    assert_equal [ [ @newcomer.id, "assignment", "Placed, but joined after the base date" ] ], items
    assert_equal({ @newcomer.id => "Nia Newcomer" }, attention[:names])
  end

  should "name where to fix each item: the employment status provider for a newcomer, else the units it touches" do
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .set_fact_provider("employment_status", "hibob", effective_on: "2026-01-01")
    end
    assign(@q2, @newcomer, { unit_id: @growth, allocation: 1 })
    write(Operations::TeamPlanning::RetireUnit, @q1, unit_id: @payments)

    sources = attention[:items].to_h { [ it[:subject_id], it[:sources] ] }
    assert_equal({ @newcomer.id => %w[hibob], @ada.id => %w[espalia], @bo.id => %w[espalia] }, sources)
  end

  def hibob_unit
    division, unit = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: division, name: "Division", provider: "hibob" }, { level_id: @department, name: "Department" },
                                  { level_id: @squad, name: "Squad" }, { level_id: @team, name: "Team" } ], effective_on: "2026-01-01")
      structure.create_unit(unit, "Sales", level_id: division, provider: "hibob", external_ref: "div-1", effective_on: "2026-01-01")
    end
    unit
  end

  def sources_of(subject_id, facet) = attention[:items].find { it.values_at(:subject_id, :facet) == [ subject_id, facet ] }[:sources]

  should "name the unit of a position an earlier step closed" do
    position = open_position(@q1, unit_id: hibob_unit)
    assign(@q2, @bo, { position_id: position, allocation: 1 })
    write(Operations::TeamPlanning::ClosePosition, @q1, position_id: position)

    assert_equal %w[hibob], sources_of(@bo.id, "assignment")
  end

  should "name the unit a stray capacity override is for" do
    sales = hibob_unit
    assign(@q1, @ada, { unit_id: sales, allocation: 1 })
    write(Operations::TeamPlanning::SetCapacityOverride, @q1, person_id: @ada.id, unit_id: sales, amount: "0.5")
    assign(@q2, @ada, { unit_id: @growth, allocation: 1 })

    assert_equal %w[hibob], sources_of(@ada.id, "capacity:#{sales}")
  end

  should "name the unit of a place no capacity model covers" do
    sales = hibob_unit
    write(Operations::TeamPlanning::SetRule, @plan_id, rule: "capacity_model", value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    assign(@q2, @bo, { unit_id: sales, allocation: 1 })

    assert_equal %w[hibob], sources_of(@bo.id, "capacity:#{sales}")
  end

  should "mark someone the plan still places once the Org Graph has them leave, by name" do
    travel_to Time.utc(2026, 3, 10, 9)
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).leave(@bo.id, **ESPALIA, effective_on: "2026-03-10")
    end

    assert_equal [ [ @bo.id, "assignment", "Placed, but has since left" ] ], items
    assert_equal({ @bo.id => "Bo Reyes" }, attention[:names])
    assert_equal %w[espalia], sources_of(@bo.id, "assignment")
  end

  should "name the manager fact's provider for a manager item" do
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .set_fact_provider("manager", "hibob", effective_on: "2026-01-01")
    end
    assign(@q2, @ada, { unit_id: @growth, allocation: 1 })
    write(Operations::TeamPlanning::SetReportingLine, @q2, person_id: @ada.id, manager_id: @bo.id)

    assert_equal %w[hibob], sources_of(@ada.id, "reporting_line")
  end

  should "read the baseline when no scenario is given" do
    write(Operations::TeamPlanning::RetireUnit, @plan_id, unit_id: @payments)

    read = call(Operations::TeamPlanning::Attention, plan_id: @plan_id)
    assert_equal @plan_id, read[:scenario_id]
    assert_equal [ @ada.id, @bo.id ].sort, read[:items].map { it[:subject_id] }
  end

  should "list the budget checks' rows by check, naming a line nothing draws on and no amount" do
    idle = ActsAsTenant.with_tenant(@tenant) do
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 90_000, currency: "AUD", period: "year", cost_centre: "Growth").id
    end

    read = call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @q1)
    row = read[:items].find { it[:check] == "unused_budget_lines" }

    assert_equal [ idle, "budget_line", "Nothing in this scenario draws on it" ], row.values_at(:subject_id, :facet, :reason)
    assert_equal "Any role · Growth", read[:names][idle]
    assert_no_pay_figure read, "90000"
  end

  should "refuse someone outside the plan, and a plan in another tenant" do
    assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { attention(as: @outsider) }.message

    other = create(:tenant)
    stranger = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }
    refused = assert_raises(Operations::Base::ParameterError) do
      ActsAsTenant.with_tenant(other) do
        Operations::TeamPlanning::Attention.call(context: AuthorizationContext.new(user: stranger.user, tenant_user: stranger, person: stranger.person),
                                                 params: { plan_id: @plan_id, scenario_id: @q2 })
      end
    end
    assert_equal "No such plan", refused.message
  end
end
