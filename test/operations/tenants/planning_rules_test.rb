# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::PlanningRulesTest < ActiveSupport::TestCase
  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { cap: 10 }
    def self.json_schema = { type: "object", properties: { cap: { type: "integer", minimum: 0 } } }

    def self.check(value)
      raise TeamPlanning::Error, "cap must be a whole number of 0 or more" unless value["cap"].is_a?(Integer) && value["cap"] >= 0

      value.slice("cap")
    end
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Admin"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, team_planner: true, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true, person: create(:person, tenant: @tenant))
    end
  end

  teardown { TeamPlanning::RuleKinds.unregister(HeadcountCap) }

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::Tenants::#{operation}".constantize.call(context: context(as), params:) }
  end

  def listed = call(:PlanningRules)[:planning_rules].find { it[:rule] == "test_headcount_cap" }

  should "list a rule with its built-in default until the tenant sets its own" do
    assert_equal({ rule: "test_headcount_cap", description: "The most people a unit may hold",
                   value_schema: HeadcountCap.json_schema, built_in_default: { "cap" => 10 },
                   tenant_default: nil, updated_at: nil, updated_by: nil }, listed)
  end

  should "set the tenant's default, recording who set it and when, and change it again" do
    travel_to Time.utc(2026, 11, 14, 9) do
      set = call(:SetPlanningRule, rule: "test_headcount_cap", value: { cap: 6 })

      assert_equal [ { "cap" => 6 }, "Ada Admin", "2026-11-14T09:00:00Z" ], set.values_at(:tenant_default, :updated_by, :updated_at)
      assert_equal set, listed
    end

    call(:SetPlanningRule, rule: "test_headcount_cap", value: { "cap" => 4 })
    assert_equal({ "cap" => 4 }, listed[:tenant_default])
    assert_equal 1, ActsAsTenant.with_tenant(@tenant) { PlanningRuleDefault.count }
  end

  should "refuse a value the rule refuses, without repeating it, and an unknown rule" do
    error = assert_raises(Operations::Base::ParameterError) { call(:SetPlanningRule, rule: "test_headcount_cap", value: { cap: -48_250 }) }
    assert_equal "cap must be a whole number of 0 or more", error.message
    assert_not_includes error.message, "48250"

    error = assert_raises(Operations::Base::ParameterError) { call(:SetPlanningRule, rule: "test_bonus_pool", value: { cap: 1 }) }
    assert_equal "No such rule", error.message

    assert_nil listed[:tenant_default]
  end

  should "refuse a planner and an Org Graph editor, to read or to set" do
    [ @member, @editor ].each do |account|
      assert_raises(Pundit::NotAuthorizedError) { call(:PlanningRules, as: account) }
      assert_raises(Pundit::NotAuthorizedError) { call(:SetPlanningRule, as: account, rule: "test_headcount_cap", value: { cap: 1 }) }
    end
    assert_nil listed[:tenant_default]
  end

  should "keep one tenant's default from another" do
    other = create(:tenant)
    other_admin = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin) }
    ActsAsTenant.with_tenant(other) do
      Operations::Tenants::SetPlanningRule.call(context: context(other_admin), params: { rule: "test_headcount_cap", value: { cap: 2 } })
    end

    assert_nil listed[:tenant_default]
  end
end
