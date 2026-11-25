# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::PlanningInputsHistoryTest < ActiveSupport::TestCase
  FIGURES = { minimum: "100000", midpoint: "120000", maximum: "140000" }.freeze
  LINE = { starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new", approved_on: "2026-10-01",
           amount: "96500", currency: "AUD", period: "year", head_count: "1" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Admin"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, team_planner: true, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true, person: create(:person, tenant: @tenant))
      @role = create(:framework_role, tenant: @tenant)
      @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
    end
  end

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::Tenants::#{operation}".constantize.call(context: context(as), params:) }
  end

  def history(inputs, **params) = call(:PlanningInputsHistory, inputs:, **params)

  def add_band(location) = call(:AddPayBand, level_id: @level.level_id, location:, currency: "AUD", period: "year", **FIGURES)

  context "pay bands" do
    setup do
      @first = add_band("Fixtureland")
      @second = add_band("Elsewhere")
      call(:ChangePayBand, pay_band_id: @first[:pay_band_id], currency: "AUD", period: "year", minimum: "100000",
                           midpoint: "125000", maximum: "140000")
      call(:ReorderPayBands, pay_band_ids: [ @second[:pay_band_id], @first[:pay_band_id] ])
      call(:RemovePayBand, pay_band_id: @second[:pay_band_id])
      @changes = history("pay_bands")[:changes]
    end

    should "list every change newest first, by whom, with the row before and after" do
      assert_equal %w[removed reordered changed added added], @changes.pluck(:change)
      assert_equal [ "Ada Admin" ], @changes.pluck(:by).uniq
      assert_equal [ false ], @changes.pluck(:already_held).uniq
      assert_equal [ "pay_band" ], @changes.pluck(:table).uniq
    end

    should "show a change's figures before and after, as tenants_pay_bands lists them" do
      changed = @changes.find { it[:change] == "changed" }

      assert_equal @first[:pay_band_id], changed[:id]
      assert_equal [ "120000.00", "125000.00" ], [ changed[:before][:midpoint], changed[:after][:midpoint] ]
      assert_equal [ "Fixtureland", "Software Engineer", "E2 Engineer II" ],
                   changed[:after].values_at(:location, :role, :level_name)
    end

    should "show the row a removal took away, and no row for a reorder" do
      removed, reordered = @changes.first(2)

      assert_equal [ "Elsewhere", nil ], [ removed[:before][:location], removed[:after] ]
      assert_equal [ nil, nil ], reordered.values_at(:before, :after)
    end

    should "name a forgotten editor as a former member" do
      ActsAsTenant.with_tenant(@tenant) { @admin.person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

      assert_equal [ Person::FORMER_MEMBER ], history("pay_bands")[:changes].pluck(:by).uniq
    end

    should "leave out the other inputs" do
      call(:SetReferenceCurrency, currency: "AUD")

      assert_equal 5, history("pay_bands")[:changes].size
      assert_equal [ "reference_currency" ], history("exchange_rates")[:changes].pluck(:table)
    end
  end

  should "mark a row recorded from the table as already held, naming no one when no account changed it" do
    ActsAsTenant.with_tenant(@tenant) do
      PayBand.create!(location: "Fixtureland", position: 1, currency: "AUD", period: "year", minimum: 1, midpoint: 2,
                      maximum: 3, role_name: "Every role", level_name: "Every level")
      TenantPlanningInputs::Reconciliation.new(@tenant).call
    end

    change = history("pay_bands")[:changes].sole

    assert_equal [ "added", true, nil ], change.values_at(:change, :already_held, :by)
    assert_equal "2.00", change[:after][:midpoint]
  end

  should "list rates and the reference currency together, with a rate's change" do
    rate = call(:AddExchangeRate, from_currency: "NZD", to_currency: "AUD", rate: "0.5", applies_from: "2026-07-01")
    call(:ChangeExchangeRate, exchange_rate_id: rate[:exchange_rate_id], rate: "0.55")
    call(:SetReferenceCurrency, currency: "AUD")
    call(:SetReferenceCurrency, currency: "NZD")

    changes = history("exchange_rates")[:changes]

    assert_equal [ %w[reference_currency changed], %w[reference_currency added], %w[exchange_rate changed], %w[exchange_rate added] ],
                 changes.map { it.values_at(:table, :change) }
    assert_equal [ { currency: "AUD" }, { currency: "NZD" } ], changes.first.values_at(:before, :after)
    assert_equal [ "0.5", "0.55" ], [ changes[2][:before][:rate], changes[2][:after][:rate] ]
  end

  should "list a budget line's figures as tenants_budget_lines does" do
    call(:AddBudgetLine, **LINE, level_id: @level.level_id, location: "Fixtureland")

    change = history("budget_lines")[:changes].sole

    assert_equal [ "budget_line", "added" ], change.values_at(:table, :change)
    assert_equal call(:BudgetLines)[:budget_lines].sole.except(:budget_line_id, :updated_at, :updated_by), change[:after]
    assert_pay_figure history("budget_lines"), "96500"
  end

  should "list a rule default as it was set, and what it replaced" do
    kind = Class.new(TeamPlanning::RuleKind) do
      def self.rule_name = "test_history_cap"
      def self.description = "A cap"
      def self.default = { cap: 10 }
      def self.json_schema = { type: "object" }
      def self.check(value) = value.slice("cap")
    end
    TeamPlanning::RuleKinds.register(kind)
    call(:SetPlanningRule, rule: "test_history_cap", value: { cap: 4 })
    call(:SetPlanningRule, rule: "test_history_cap", value: { cap: 6 })

    change = history("planning_rules")[:changes].first

    assert_equal [ "planning_rule_default", "changed" ], change.values_at(:table, :change)
    assert_equal [ { "cap" => 4 }, { "cap" => 6 } ], [ change[:before][:value], change[:after][:value] ]
  ensure
    TeamPlanning::RuleKinds.unregister(kind)
  end

  should "page 25 changes at a time" do
    band = add_band("Fixtureland")
    25.times { |index| call(:ChangePayBand, pay_band_id: band[:pay_band_id], currency: "AUD", period: "year", **FIGURES, midpoint: (120_001 + index).to_s) }

    first = history("pay_bands")
    second = history("pay_bands", page: 2)

    assert_equal [ 1, true, 25 ], [ first[:page], first[:next_page], first[:changes].size ]
    assert_equal [ 2, false, [ "added" ] ], [ second[:page], second[:next_page], second[:changes].pluck(:change) ]
  end

  should "refuse inputs it doesn't know" do
    error = assert_raises(Operations::Base::ParameterError) { history("people") }
    assert_equal "inputs must be one of pay_bands, exchange_rates, budget_lines, planning_rules", error.message
  end

  should "refuse anyone but a tenant admin, a planner and an Org Graph editor included" do
    add_band("Fixtureland")

    [ @member, @editor ].each do |account|
      %w[pay_bands exchange_rates budget_lines planning_rules].each do |inputs|
        assert_raises(Pundit::NotAuthorizedError) { history(inputs, as: account) }
      end
    end
  end
end
