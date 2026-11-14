# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::SetRuleTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }

    def self.check(value)
      raise TeamPlanning::Error, "A cap must be a whole number of people" unless value["cap"].is_a?(Integer) && value["cap"] >= 0

      value
    end
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    departments = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(:CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(:AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(:ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    @q2 = call(:ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]
  end

  teardown { TeamPlanning::RuleKinds.unregister(HeadcountCap) }

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @editor, **params)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context: context_for(as), params:) }
  end

  def set_cap(scenario_id, value, as: @editor, **scope)
    call(:SetRule, as:, plan_id: @plan_id, scenario_id:, rule: "test_headcount_cap", value:, **scope)
  end

  def cap(scenario_id, unit_id: nil)
    as_tenant do
      plan = TeamPlanningPlan.find(@plan_id)
      TeamPlanning::Resolution.new(context: context_for(@editor), plan:, scenario_id:).structure.rule("test_headcount_cap", unit_id:)["cap"]
    end
  end

  def stream_size = as_tenant { Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).count }

  should "set a rule for the whole plan, which later steps inherit" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, subject_id: @plan_id, rule: "test_headcount_cap", value: { "cap" => 8 } },
                 set_cap(@q1, { cap: 8 }))

    assert_equal [ 10, 8, 8 ], [ @plan_id, @q1, @q2 ].map { cap(it) }
  end

  should "set a rule for one unit, leaving the plan-wide value alone" do
    set_cap(@q1, { cap: 3 }, unit_id: @engineering.upcase)

    assert_equal [ 3, 10 ], [ cap(@q1, unit_id: @engineering), cap(@q1) ]
  end

  should "follow the parent again once the change is cleared" do
    set_cap(@q1, { cap: 8 })
    set_cap(@q2, { cap: 5 })
    call(:ClearChange, plan_id: @plan_id, scenario_id: @q2, subject_id: @plan_id, facet: "rule:test_headcount_cap")

    assert_equal 8, cap(@q2)
  end

  should "refuse an unknown rule, and a value its kind refuses, without repeating the value" do
    assert_equal "No such rule", assert_raises(Operations::Base::ParameterError) {
      call(:SetRule, plan_id: @plan_id, scenario_id: @q1, rule: "no_such_rule", value: {})
    }.message

    refused = assert_raises(Operations::Base::ParameterError) { set_cap(@q1, { cap: "eleventy" }) }
    assert_equal "A cap must be a whole number of people", refused.message
  end

  should "refuse a viewer and an outsider as an unknown plan, writing nothing" do
    before = stream_size
    [ @viewer, @outsider ].each do |who|
      assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { set_cap(@q1, { cap: 8 }, as: who) }.message
    end
    assert_equal before, stream_size
  end
end
