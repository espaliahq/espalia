# frozen_string_literal: true

require "test_helper"

# An open seat with no target start is forecast to fill time_to_hire days after
# it opens ([#458](https://github.com/espaliahq/espalia/issues/458)). Cost loses
# the empty days; headcount and capacity lose the seat only when it fills after
# the step's last day.
class Operations::TeamPlanning::HiringLagTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @unit_id = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5)
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 73_000, maximum: 200_000)
      squads = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@unit_id, "Payments", level_id: squads, effective_on: "2026-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                            value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    @q2 = fork(relation: "then", name: "Q2", ends_on: "2026-06-30")
    @q3 = fork(parent_id: @q2, relation: "then", name: "Q3", ends_on: "2026-09-30")
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def open_position(**hiring)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q2, role_id: @engineer.role_id,
                                                level_id: @e5.level_id, unit_id: @unit_id, fte: 1, basis: "new", **hiring)[:position_id]
  end

  def lags(scenario_id)
    call(Operations::TeamPlanning::Forecast, plan_id: @plan_id, scenario_id:)[:rows].select { it[:kind] == "time_to_hire" }
                                                                                     .map { it.slice(:unit_id, :headcount, :cost, :capacity) }
  end

  # Every native figure of one part, wherever the cost report shows it.
  def parts(report, part)
    found = []
    walk = lambda do |node|
      case node
      when Hash
        found << node[part][:native] if node[part].is_a?(Hash) && node[part].key?(:native)
        node.each_value { walk.(it) }
      when Array then node.each { walk.(it) }
      end
    end
    walk.(report)
    found
  end

  def time_to_hire(days, scenario_id: @plan_id)
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id:, rule: "time_to_hire", value: { days: days.to_s })
  end

  should "cost the 90 days an undated seat stays empty, and keep it in headcount and capacity once it fills inside the step" do
    open_position

    assert_equal [ { unit_id: @unit_id, headcount: "0", cost: { "EUR" => "-18000" }, capacity: {} } ], lags(@q2)
    assert_empty lags(@q3), "the seat filled on 31 May"
  end

  should "take the seat out of headcount and capacity in a step it fills after, and carry the rest into the next" do
    open_position
    time_to_hire(200)

    assert_equal [ { unit_id: @unit_id, headcount: "-1", cost: { "EUR" => "-24200" }, capacity: { "per_fte" => "-1" } } ], lags(@q2)
    assert_equal [ { unit_id: @unit_id, headcount: "0", cost: { "EUR" => "-15800" }, capacity: {} } ], lags(@q3),
                 "1 July to 17 September, filling on the 18th"
  end

  should "file the lag under the seat's cost centre in cost and capacity alike" do
    open_position(cost_centre: "Growth")
    time_to_hire(200)

    assert_equal [ [ "Growth", "-1", { "EUR" => "-24200" }, { "per_fte" => "-1" } ] ],
                 call(Operations::TeamPlanning::Forecast, plan_id: @plan_id, scenario_id: @q2)[:rows]
                   .select { it[:kind] == "time_to_hire" }.map { it.values_at(:cost_centre, :headcount, :cost, :capacity) }
  end

  should "leave a seat with a target start, or on hold, to its own dates" do
    open_position(target_start: "2026-04-01")
    open_position(hiring_status: "on_hold", target_start: "2026-05-01")

    assert_empty lags(@q2)
  end

  should "read the lag at the seat's unit" do
    open_position
    time_to_hire(200)
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, unit_id: @unit_id, rule: "time_to_hire", value: { days: "0" })

    assert_empty lags(@q2)
  end

  should "give back today's figures exactly when the tenant sets time_to_hire to 0" do
    open_position
    lagging = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @q2)
    call(Operations::Tenants::SetPlanningRule, rule: "time_to_hire", value: { days: "0" })
    report = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @q2)

    assert_empty lags(@q2)
    assert_empty lags(@q3)
    assert_equal [ {} ], parts(report, :forecast).uniq, "no forecast anywhere"
    assert_equal parts(lagging, :planned), parts(report, :planned)
    assert_equal parts(report, :planned), parts(report, :scenario), "the total is the plan itself"
  end
end
