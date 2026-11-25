# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ScenarioCostsTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    teams = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, effective_on: "2025-01-01")

      @ada, @cy = %w[Ada Cy].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                               cost_centre: "CC-1")
      people.record_person(@cy.id, **ESPALIA, employment_status: "employed", title: "Juggler", level: "5", fte: 1.0)
      people.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      people.set_membership(@cy.id, @payments, **ESPALIA, allocation: 1.0)

      add_pay_band!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "EUR")

      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-01-01")[:plan_id]
    @year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    # These price open seats from the day they open; the hiring lag has its own tests.
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "time_to_hire", value: { days: "0" })
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def costs(as: @admin) = call(Operations::TeamPlanning::ScenarioCosts, as:, plan_id: @plan_id)

  should "give every scenario's totals, the same as team_planning_cost gives each" do
    later = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @year, relation: "then", name: "2027", ends_on: "2027-12-31")[:scenario_id]
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @year, role_id: @engineer.role_id,
                                                 level_id: @e5.level_id, unit_id: @payments, fte: 0.5, basis: "new")
    result = costs

    assert_equal [ "EUR", "2025-12-15T09:00:00Z" ], result.values_at(:reference_currency, :bands_changed_at)
    assert_equal [ @plan_id, @year, later ], result[:scenarios].pluck(:scenario_id)
    assert_equal %w[run_rate period period], result[:scenarios].pluck(:basis)
    [ @plan_id, @year, later ].each do |scenario_id|
      one = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id:)
      row = result[:scenarios].find { it[:scenario_id] == scenario_id }
      assert_equal one[:total], row[:total]
      assert_equal [ one[:period], one[:unpriced].size ], row.values_at(:period, :unpriced)
      assert_equal one[:run_rate_at_end].slice(:on, :open_ended, :horizon_months, :total), row[:run_rate_at_end] unless scenario_id == @plan_id
    end
    assert_equal "50000", result[:scenarios].second[:total][:difference][:converted]
    assert_equal [ nil, "2026-12-31", "2027-12-31" ], result[:scenarios].map { it.dig(:run_rate_at_end, :on) }
  end

  should "read the Org Graph once, however many scenarios the plan has" do
    2.times { |index| call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @year, relation: "instead", name: "Option #{index}") }
    reads = 0
    as_of = OrgGraph::AsOf.method(:new)
    OrgGraph::AsOf.stub(:new, ->(**args) { reads += 1; as_of.call(**args) }) { costs }

    assert_equal 1, reads
  end

  should "say why a scenario can't be priced, and still price the rest" do
    error = TeamPlanning::Error.new("No such scenario")
    every = TeamPlanning::Cost.method(:every_scenario)
    broken = ->(**args) { every.call(**args).merge("gone" => error) }
    result = TeamPlanning::Cost.stub(:every_scenario, broken) { costs }

    assert_equal({ scenario_id: "gone", error: "No such scenario" }, result[:scenarios].last)
    assert result[:scenarios].first[:total]
  end

  should "read as an unknown plan to anyone outside it" do
    error = assert_raises(Operations::Base::ParameterError) { costs(as: @outsider) }
    assert_equal "No such plan", error.message
  end
end
