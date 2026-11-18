# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ScenarioMapTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: (level_id = SecureRandom.uuid_v7), name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id:, effective_on: "2026-01-01")
    end
    @plan_id = call(:CreatePlan, name: "Next year", base_on: "2026-01-15")[:plan_id]
    @q1 = call(:ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    @q2 = call(:ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]
    travel_to Time.utc(2026, 7, 1, 9)
    call(:CloseStep, plan_id: @plan_id, scenario_id: @q1)
  end

  def call(operation, **params)
    context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
    ActsAsTenant.with_tenant(@tenant) { "Operations::TeamPlanning::#{operation}".constantize.call(context:, params:) }
  end

  should "read a step after a closed step as the Org Graph knows it now" do
    map = call(:ScenarioMap, plan_id: @plan_id, scenario_id: @q2)

    assert_equal [ "2026-07-01", nil ], map.values_at(:base_on, :known_on)
  end
end
