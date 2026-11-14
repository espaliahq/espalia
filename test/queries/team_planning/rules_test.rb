# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RulesTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  # Test-only kinds, standing in for those 5.2, 7.1 and 8.1 add.
  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }

    def self.check(value)
      raise TeamPlanning::Error, "cap must be a whole number of 0 or more" unless value["cap"].is_a?(Integer) && value["cap"] >= 0

      value.slice("cap")
    end
  end

  class Strictness < TeamPlanning::RuleKind
    def self.rule_name = "test_strictness"
    def self.description = "Whether going over budget is refused or only flagged"
    def self.default = { "level" => "flag" }
  end

  # Stands in for 3.4's retirement: the unit leaves the map, its children with no parent.
  class UnitRetired < TeamPlanning::Events::Change
    def self.facet = "retired"

    def self.apply_to(map, data)
      units = map.units.reject { it.id == data[:subject_id] }
      map.with(units: units.map { it.parent_id == data[:subject_id] ? it.with(parent_id: nil) : it })
    end
  end

  setup do
    [ HeadcountCap, Strictness ].each { TeamPlanning::RuleKinds.register(it) }
    @tenant = create(:tenant)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments, squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @sales = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure.define_taxonomy([ { level_id: departments, name: "Department" }, { level_id: squads, name: "Squad" } ],
                                effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squads, parent_id: @engineering, effective_on: "2026-01-01")
      structure.create_unit(@sales, "Sales", level_id: departments, effective_on: "2026-01-01")

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @lean = fork(@q1, "instead", "Lean Q1")
    end
  end

  teardown { [ HeadcountCap, Strictness ].each { TeamPlanning::RuleKinds.unregister(it) } }

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler(as = @planner) = TeamPlanning::CommandHandler.new(actor: context_for(as))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set_rule(scenario_id, subject_id, rule, value)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id:, end_state: { rule:, value: })
    end
  end

  def cap(scenario_id, unit_id: nil) = resolve(scenario_id).rule("test_headcount_cap", unit_id:)["cap"]

  def resolve(scenario_id, as: @planner)
    as_tenant do
      TeamPlanning::Resolution.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id), scenario_id:).structure
    end
  end

  should "read a kind's built-in default until something sets the rule" do
    assert_equal 10, cap(@plan_id)
    assert_equal 10, cap(@q1, unit_id: @payments)
  end

  should "read the tenant's own default over the built-in one, and only this tenant's" do
    as_tenant { PlanningRuleDefault.create!(rule: "test_headcount_cap", value: { cap: 7 }) }
    other = create(:tenant)
    as_tenant(other) { PlanningRuleDefault.create!(rule: "test_headcount_cap", value: { cap: 2 }) }

    assert_equal [ 7, 7 ], [ cap(@plan_id), cap(@lean, unit_id: @payments) ]
  end

  should "let the root override the tenant's default" do
    as_tenant { PlanningRuleDefault.create!(rule: "test_headcount_cap", value: { cap: 7 }) }
    set_rule(@plan_id, @plan_id, "test_headcount_cap", { cap: 8 })

    assert_equal [ 8, 8 ], [ cap(@plan_id), cap(@q1) ]
  end

  should "let the root override the default, and carry it down every step" do
    set_rule(@plan_id, @plan_id, "test_headcount_cap", { cap: 8 })

    assert_equal [ 8, 8, 8 ], [ cap(@plan_id), cap(@q1), cap(@lean, unit_id: @sales) ]
  end

  should "let an alternative override its parent, and leave the parent as it was" do
    set_rule(@q1, @plan_id, "test_headcount_cap", { cap: 8 })
    set_rule(@lean, @plan_id, "test_headcount_cap", { cap: 5 })

    assert_equal [ 10, 8, 5 ], [ cap(@plan_id), cap(@q1), cap(@lean) ]
  end

  should "reach a unit's rule down its subtree and not across to its siblings" do
    set_rule(@q1, @plan_id, "test_headcount_cap", { cap: 8 })
    set_rule(@q1, @engineering, "test_headcount_cap", { cap: 3 })

    assert_equal [ 3, 3, 8, 8 ],
                 [ cap(@q1, unit_id: @engineering), cap(@q1, unit_id: @payments), cap(@q1, unit_id: @sales), cap(@q1) ]
  end

  should "let a unit's rule win over the one above it" do
    set_rule(@q1, @engineering, "test_headcount_cap", { cap: 3 })
    set_rule(@q1, @payments, "test_headcount_cap", { cap: 1 })

    assert_equal [ 3, 1 ], [ cap(@q1, unit_id: @engineering), cap(@q1, unit_id: @payments) ]
  end

  should "drop a retired unit's rules from the units it held" do
    set_rule(@plan_id, @engineering, "test_headcount_cap", { cap: 3 })
    as_tenant { handler.set_change(@plan_id, UnitRetired, scenario_id: @q1, subject_id: @engineering) }

    assert_equal 3, cap(@plan_id, unit_id: @payments)
    assert_equal 10, cap(@q1, unit_id: @payments)
    error = assert_raises(TeamPlanning::Error) { cap(@q1, unit_id: @engineering) }
    assert_equal "No such unit", error.message
  end

  should "land two rules on one subject, each on its own" do
    set_rule(@q1, @engineering, "test_headcount_cap", { cap: 3 })
    set_rule(@q1, @engineering, "test_strictness", { level: "refuse" })

    map = resolve(@q1)
    assert_equal 3, map.rule("test_headcount_cap", unit_id: @engineering)["cap"]
    assert_equal({ "level" => "refuse" }, map.rule("test_strictness", unit_id: @engineering))
  end

  should "keep the last value a scenario sets for a rule" do
    set_rule(@q1, @plan_id, "test_headcount_cap", { cap: 8 })
    set_rule(@q1, @plan_id, "test_headcount_cap", { cap: 6 })

    assert_equal 6, cap(@q1)
  end

  should "refuse a value its kind refuses, without repeating the value" do
    error = assert_raises(TeamPlanning::Error) { set_rule(@q1, @plan_id, "test_headcount_cap", { cap: -48_250 }) }

    assert_equal "cap must be a whole number of 0 or more", error.message
    assert_not_includes error.message, "48250"
    assert_empty as_tenant { TeamPlanning::Repository.new.load_plan(@plan_id).changes_in(@q1) }
  end

  should "refuse a rule no kind names, a value that isn't an object, and a field a rule doesn't take" do
    assert_equal "No such rule", assert_raises(TeamPlanning::Error) { set_rule(@q1, @plan_id, "test_bonus_pool", { cap: 1 }) }.message
    assert_equal "A rule's value must be an object", assert_raises(TeamPlanning::Error) { set_rule(@q1, @plan_id, "test_headcount_cap", 4) }.message

    error = assert_raises(TeamPlanning::Error) do
      as_tenant do
        handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @q1, subject_id: @plan_id,
                                                                     end_state: { rule: "test_headcount_cap", value: { cap: 1 }, note: "x" })
      end
    end
    assert_equal "A rule takes only rule and value, not note", error.message
  end

  should "refuse to read a rule no kind names" do
    assert_equal "No such rule", assert_raises(TeamPlanning::Error) { resolve(@q1).rule("test_bonus_pool") }.message
  end

  should "refuse someone who can't open the plan" do
    outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))

    assert_raises(Pundit::NotAuthorizedError) { resolve(@q1, as: outsider) }
  end
end
