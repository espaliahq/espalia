# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TenantPlanningInputs::Projections::TablesTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  PROJECTION = TenantPlanningInputs::Projections::Tables

  setup do
    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def band(location) = PayBand.new(location:, currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3).tap { it.match_on }

  # Every column of every row, ids and timestamps too, and the bands' stamp.
  def everything
    TenantPlanningInputs::Rows::TABLES.each_key.to_h do |table|
      [ table, TenantPlanningInputs::Rows.model(table).unscoped.where(tenant_id: @tenant.id).order(:id).map(&:attributes) ]
    end.merge(stamp: Tenant.where(id: @tenant.id).pick(:pay_bands_changed_at))
  end

  def write_one_of_each
    as_tenant do
      first = save_planning_input!(:pay_bands, band("Fixtureland"), changed_by_id: @person.id)
      second = save_planning_input!(:pay_bands, band("Testonia"))
      gone = save_planning_input!(:pay_bands, band("Mu"))
      reorder_pay_bands!([ second.id, gone.id, first.id ])
      remove_planning_inputs!(gone)
      save_planning_input!(:pay_bands, PayBand.find(first.id).tap { it.midpoint = 2.5 }, changed_by_id: @person.id)
      add_planning_input!(:exchange_rates, from_currency: "NZD", to_currency: "AUD", rate: "0.9", applies_from: "2026-07-01")
      add_planning_input!(:reference_currencies, currency: "AUD")
      add_planning_input!(:budget_lines, starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 1_000, currency: "AUD", period: "year")
      add_planning_input!(:planning_rule_defaults, rule: "test_headcount_cap", value: { cap: 4 })
    end
  end

  should "write each row as its events leave it, keeping the id the command minted" do
    write_one_of_each

    as_tenant do
      assert_equal [ "Testonia", "Fixtureland" ], PayBand.order(:position).pluck(:location)
      assert_equal [ 1, 2 ], PayBand.order(:position).pluck(:position)
      assert_equal [ BigDecimal("2.5"), @person.id ], PayBand.find_by(location: "Fixtureland").values_at(:midpoint, :updated_by_person_id)
      assert_equal 1, [ ExchangeRate, ReferenceCurrency, BudgetLine, PlanningRuleDefault ].map(&:count).uniq.sole
    end
    assert_not_nil Tenant.find(@tenant.id).pay_bands_changed_at
  end

  should "write the same rows, every column and id, from a reset as live" do
    write_one_of_each
    live = everything

    PROJECTION.reset!(tenant: @tenant)
    assert_equal live, everything

    Projections::Replayer.replay(projection_class: PROJECTION, tenant: @tenant)
    assert_equal live, everything
  end

  should "rebuild the same rows with every projection at once" do
    write_one_of_each
    live = everything

    Projections::GlobalReplayer.replay_all(tenant: @tenant)
    assert_equal live, everything
  end

  should "leave another tenant's rows alone" do
    other = create(:tenant)
    ActsAsTenant.with_tenant(other) { save_planning_input!(:pay_bands, band("Fixtureland")) }
    write_one_of_each

    PROJECTION.reset!(tenant: @tenant)

    assert_equal 1, PayBand.unscoped.where(tenant_id: other.id).count
  end
end
