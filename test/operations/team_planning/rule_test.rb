# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::RuleTest < ActiveSupport::TestCase
  FLAT = { "model" => "flat", "params" => { "percent" => "11" } }.freeze
  BY_COUNTRY = { "model" => "by_country", "params" => { "percents" => { "Atlantis" => "14" }, "otherwise" => "10" } }.freeze

  setup do
    @tenant = create(:tenant)
    departments, squads = Array.new(2) { SecureRandom.uuid_v7 }
    @engineering, @payments = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: departments, name: "Department" }, { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squads, parent_id: @engineering, effective_on: "2026-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @admin, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def on_cost(scenario_id = @q1, as: @admin, **scope)
    call(Operations::TeamPlanning::Rule, as:, plan_id: @plan_id, scenario_id:, rule: "on_cost", **scope)[:value]
  end

  should "read the rule's own default, then the tenant's, then the plan's" do
    assert_equal TeamPlanning::RuleKinds::OnCost.default, on_cost

    call(Operations::Tenants::SetPlanningRule, rule: "on_cost", value: FLAT)
    assert_equal FLAT, on_cost

    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, rule: "on_cost", value: BY_COUNTRY)
    assert_equal [ FLAT, BY_COUNTRY ], [ on_cost(@plan_id), on_cost ]
  end

  should "read a cost_centre value stored as a first-match rules list as its entries, in the order that gives the same answers" do
    rules = [ { "unit_id" => @payments, "cost_centre" => "Payments" }, { "unit_id" => @engineering, "cost_centre" => "Engineering" } ]
    as_tenant { PlanningRuleDefault.create!(rule: "cost_centre", value: { "rules" => rules }) }

    value = call(Operations::TeamPlanning::Rule, plan_id: @plan_id, scenario_id: @q1, rule: "cost_centre")[:value]

    assert_equal({ "entries" => rules.reverse }, value)
  end

  should "read a unit's rule over the plan-wide one, for the units below it too" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, unit_id: @engineering, rule: "on_cost", value: FLAT)

    assert_equal [ FLAT, FLAT, TeamPlanning::RuleKinds::OnCost.default ],
                 [ on_cost(unit_id: @engineering), on_cost(unit_id: @payments), on_cost ]
  end

  should "read the plan-wide value at a unit retired in the scenario, and refuse an id it never held" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, rule: "on_cost", value: FLAT)
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments, rule: "on_cost", value: BY_COUNTRY)
    call(Operations::TeamPlanning::RetireUnit, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments)

    assert_equal FLAT, on_cost(unit_id: @payments)
    assert_equal "There is no such unit in this scenario",
                 assert_raises(Operations::Base::ParameterError) { on_cost(unit_id: SecureRandom.uuid_v7) }.message
  end

  should "refuse an unknown rule and anyone outside the plan" do
    assert_equal "No such rule", assert_raises(Operations::Base::ParameterError) {
      call(Operations::TeamPlanning::Rule, plan_id: @plan_id, scenario_id: @q1, rule: "no_such_rule")
    }.message
    assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { on_cost(as: @outsider) }.message
  end
end
