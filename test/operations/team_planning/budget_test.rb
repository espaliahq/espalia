# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::BudgetTest < ActiveSupport::TestCase
  YEAR = { starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new" }.freeze

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 12, 1, 9)
    as_tenant do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      PayBand.create!(level: @e2, currency: "EUR", period: "year", minimum: 0, midpoint: 73_000, maximum: 100_000)
      ReferenceCurrency.create!(currency: "EUR")
      @platform = BudgetLine.create!(**YEAR, amount: 146_000, currency: "EUR", period: "year", head_count: 2, cost_centre: "Platform")
    end
    @unit_id = SecureRandom.uuid_v7
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2027-01-01")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
    @seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id, level_id: @e2.level_id,
                                                        unit_id: @unit_id, fte: 0.5, basis: "new", cost_centre: "Platform")[:position_id]
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @admin, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def budget(scenario_id = @q1, as: @admin) = call(Operations::TeamPlanning::Budget, as:, plan_id: @plan_id, scenario_id:)

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  # Q1 holds 90 of the year's 365 days, so the line approves 36,000 and the
  # half-time seat costs 9,000.
  should "give a member the four numbers per line, cost centre and unit, each on the stated basis" do
    read = budget(as: @viewer)

    assert_equal [ @plan_id, @q1, "inclusive", "band_midpoints", "EUR" ], read.values_at(:plan_id, :scenario_id, :basis, :pay_view, :reference_currency)
    assert_equal({ budget_line_id: @platform.id, cost_centre: "Platform", currency: "EUR",
                   approved: { amount: "36000", head_count: "2" }, funded: { native: { "EUR" => "9000" }, positions: 1, fte: "0.5" },
                   remaining: { amount: "27000", head_count: "1.5" }, mismatched_currencies: [],
                   over: { money: [], heads: false, mismatched_currencies: [] } }, read[:budget_lines].sole)
    assert_equal({ preset: "position_control", match: %w[role level cost_centre location], limit: "both", scope: "line" }, read[:strictness])
    assert_equal [ nil, nil ], [ read[:total][:over], read[:cost_centres].sole[:over] ], "position control holds each line, and nothing above it"
    assert_equal({ native: { "EUR" => "9000" }, converted: "9000", missing: [], positions: 1, fte: "0.5" }, read[:total][:funded])
    assert_equal({ native: {}, converted: "0", missing: [], positions: 0, fte: "0" }, read[:total][:unfunded])
    assert_equal [ "Platform" ], read[:cost_centres].pluck(:cost_centre)
    assert_equal({ native: { "EUR" => "9000" }, positions: 1, fte: "0.5" }, read[:cost_centres].sole[:funded], "only the total converts")
    assert_equal({ native: { "EUR" => "9000" }, positions: 1, fte: "0.5" }, read[:units].sole[:funded])
    assert_equal({ native: {}, converted: "0", missing: [] }, read[:forecast], "the forecast is scenario-wide, so it converts")
    assert_equal [ [ nil, "9000", 1 ] ], read[:units].map { [ it[:unit_id], it[:funded][:native]["EUR"], it[:funded][:positions] ] }, "a unit the map doesn't hold is no unit, as in the cost read"
    assert_empty read[:unpriced]
  end

  should "follow the budget_basis rule" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, rule: "budget_basis", value: { basis: "base_only" })

    assert_equal "base_only", budget[:basis]
    assert_match "budget_basis is set for the whole plan, not a unit",
                 refusal { call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, unit_id: @unit_id, rule: "budget_basis", value: { basis: "inclusive" }) }
    assert_match "basis must be inclusive or base_only",
                 refusal { call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, rule: "budget_basis", value: { basis: "net" }) }
  end

  should "judge over where budget_strictness holds the budget" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @q1, rule: "budget_strictness", value: { match: %w[cost_centre], limit: "heads", scope: "organisation" })
    read = budget

    assert_equal({ preset: nil, match: %w[cost_centre], limit: "heads", scope: "organisation" }, read[:strictness])
    assert_equal({ money: nil, heads: false, mismatched_currencies: [] }, read[:total][:over])
    assert_nil read[:budget_lines].sole[:over]
  end

  should "refuse a non-member as an unknown plan, and the baseline" do
    assert_match(/No such plan/, refusal { budget(as: @outsider) })
    assert_match(/baseline has no period/, refusal { budget(@plan_id) })
  end
end
