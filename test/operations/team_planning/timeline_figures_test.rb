# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::TimelineFiguresTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    squads = SecureRandom.uuid_v7
    payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2025-01-01")
      structure.create_unit(payments, "Payments", level_id: squads, effective_on: "2025-01-01")
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      people.record_person(ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                              country: "Mu", cost_centre: "Platform")
      people.set_membership(ada.id, payments, **ESPALIA, allocation: 1.0)
      ReferenceCurrency.create!(currency: "EUR")
      PayBand.create!(level: e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 150_000, currency: "EUR", period: "year",
                         cost_centre: "Platform", head_count: 2)
      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-01-01")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @h1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "H1", ends_on: "2026-06-30")[:scenario_id]
  end

  def call(operation, as: @planner, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def figures(as: @planner) = call(Operations::TeamPlanning::TimelineFigures, as:, plan_id: @plan_id, scenario_id: @h1)

  should "give Today its run rate and each step its cost, budget and capacity, as their own tools do" do
    result = figures
    today, step = result[:steps]
    cost = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @h1)
    budget = call(Operations::TeamPlanning::Budget, plan_id: @plan_id, scenario_id: @h1)

    assert_equal [ @plan_id, @h1 ], result[:steps].pluck(:scenario_id)
    assert_equal [ "run_rate", nil ], today.values_at(:basis, :budget)
    assert_equal cost[:total][:scenario], step[:cost]
    assert_equal budget[:total].slice(:approved, :funded, :unfunded, :over), step[:budget]
    assert_equal({ starts_on: "2026-01-01", ends_on: "2026-06-30", open_ended: false, horizon_months: nil }, step[:period])
    assert_equal [ "band_ranges", true, "EUR" ], result.values_at(:pay_view, :money, :reference_currency)
  end

  should "keep every budget money key null for a member without the see-pay right, and every head count" do
    result = figures(as: @viewer)
    budget = result[:steps].last[:budget]

    assert_equal [ "band_midpoints", false ], result.values_at(:pay_view, :money)
    assert_equal({ native: nil, converted: nil, missing: nil }, budget[:unfunded].slice(:native, :converted, :missing))
    assert_equal figures[:steps].last[:budget][:unfunded].slice(:positions, :fte), budget[:unfunded].slice(:positions, :fte)
  end

  should "refuse a caller who isn't in the plan" do
    error = assert_raises(Operations::Base::ParameterError) { figures(as: @outsider) }
    assert_equal "No such plan", error.message
  end
end
