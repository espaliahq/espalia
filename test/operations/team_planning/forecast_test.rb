# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ForecastTest < ActiveSupport::TestCase
  class Hiring < TeamPlanning::ForecastKind
    def self.rule_name = "test_forecast_hiring"
    def self.description = "Forecast hires per unit"
    def self.default = { "hires" => "0" }

    def self.forecast(frame)
      frame.map.units.filter_map do |unit|
        hires = Rational(frame.rule_at(unit.id)["hires"])
        frame.row(unit_id: unit.id, cost_centre: "CC-F", headcount: hires, cost: { "EUR" => hires * 1000 }, capacity: { "per_fte" => hires / 3 }) if hires.positive?
      end
    end
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      teams = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, effective_on: "2025-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
    end
    TeamPlanning::RuleKinds.register(Hiring)
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-01-01")[:plan_id]
    @year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
  end

  teardown { TeamPlanning::RuleKinds.unregister(Hiring) }

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def forecast(as: @admin, scenario_id: @year) = call(Operations::TeamPlanning::Forecast, as:, plan_id: @plan_id, scenario_id:)

  should "list each row with its unit, step and figures as decimal strings, and no id" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @year, unit_id: @payments, rule: "test_forecast_hiring", value: { hires: "2" })

    assert_equal [ { kind: "test_forecast_hiring", unit_id: @payments, unit_name: "Payments", cost_centre: "CC-F",
                     starts_on: "2026-01-01", ends_on: "2026-12-31", headcount: "2",
                     cost: { "EUR" => "2000" }, capacity: { "per_fte" => "0.66666666666666666667" } } ], forecast[:rows]
  end

  should "give the same forecast the cost read counts" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @year, unit_id: @payments, rule: "test_forecast_hiring", value: { hires: "2" })
    cost = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @year)

    assert_equal({ "EUR" => "2000" }, cost[:total][:parts][:forecast][:native])
  end

  should "price attrition's row for both cost and capacity, at the unit's average filled seat" do
    ActsAsTenant.with_tenant(@tenant) do
      family = create(:framework_role_family, name: "Engineering")
      role = create(:framework_role, code: "E", name: "Software Engineer", role_family_id: family.role_family_id)
      level = create(:framework_level, role_id: role.role_id, ordinal: 5, title: "Senior SWE")
      PayBand.create!(level:, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      people.record_person(ada.id, provider: "espalia", effective_on: "2025-12-01", employment_status: "employed", title: "Software Engineer", level: "5")
      people.set_membership(ada.id, @payments, provider: "espalia", effective_on: "2025-12-01", allocation: 1.0)
      @family_id = family.role_family_id
    end
    { "capacity_model" => { families: { @family_id => { model: "per_fte" } }, roles: {} },
      "attrition" => { yearly_rate: "0.1" }, "time_to_hire" => { days: "73" } }.each do |rule, value|
      call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @year, rule:, value:)
    end

    assert_equal [ { kind: "attrition", unit_id: @payments, unit_name: "Payments", cost_centre: nil,
                     starts_on: "2026-01-01", ends_on: "2026-12-31", headcount: "-0.02",
                     cost: { "EUR" => "-1800" }, capacity: { "per_fte" => "-0.018" } } ], forecast[:rows]
  end

  should "give Today no rows, and refuse a caller outside the plan" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "test_forecast_hiring", value: { hires: "1" })

    assert_empty forecast(scenario_id: @plan_id)[:rows]
    assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { forecast(as: @outsider) }.message
  end
end
