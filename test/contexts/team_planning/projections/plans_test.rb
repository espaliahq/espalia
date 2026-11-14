# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TeamPlanning::Projections::PlansTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @person = create(:person, tenant: @tenant)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person: @person, role: :admin)
    @handler = TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user:, tenant_user:, person: @person))
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "keep a row per live plan under the plan's own id" do
    plan_id = SecureRandom.uuid_v7
    @handler.create_plan(plan_id, name: "Next year", base_on: "2026-11-14")
    @handler.rename_plan(plan_id, "Next financial year")

    plan = TeamPlanningPlan.find(plan_id)
    assert_equal "Next financial year", plan.name
    assert_equal Date.new(2026, 11, 14), plan.base_on
    assert_equal @person.id, plan.created_by_id
  end

  should "drop a deleted plan's row" do
    plan_id = SecureRandom.uuid_v7
    @handler.create_plan(plan_id, name: "Scratch", base_on: "2026-11-14")
    @handler.delete_plan(plan_id)

    assert_not TeamPlanningPlan.exists?(plan_id)
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      kept, renamed, deleted = Array.new(3) { SecureRandom.uuid_v7 }
      @handler.create_plan(kept, name: "Kept", base_on: "2026-11-14")
      @handler.create_plan(renamed, name: "Draft", base_on: "2026-07-01")
      @handler.rename_plan(renamed, "Second half")
      @handler.create_plan(deleted, name: "Gone", base_on: "2026-11-14")
      @handler.delete_plan(deleted)

      before = snapshot_read_models(TeamPlanning::Projections::Plans, @tenant)
      assert_equal 2, before[:plans].size

      TeamPlanning::Projections::Plans.reset!(tenant: @tenant)
      assert_equal 0, TeamPlanningPlan.count
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::Plans, tenant: @tenant)

      assert_equal before, snapshot_read_models(TeamPlanning::Projections::Plans, @tenant)
    end
  end
end
