# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TeamPlanning::Projections::PlanMembersTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @person = create(:person, tenant: @tenant)
    @colleague = create(:person, tenant: @tenant)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person: @person, role: :admin)
    @handler = TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user:, tenant_user:, person: @person))
    @plan_id = SecureRandom.uuid_v7
    @handler.create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def roles = TeamPlanningPlanMember.where(plan_id: @plan_id).pluck(:person_id, :role).sort

  should "make the creator its first editor, and follow each change of role" do
    assert_equal [ [ @person.id, "editor" ] ], roles

    @handler.add_member(@plan_id, @colleague.id, role: "viewer")
    @handler.add_member(@plan_id, @colleague.id, role: "editor")
    assert_equal [ [ @person.id, "editor" ], [ @colleague.id, "editor" ] ].sort, roles

    plan = TeamPlanningPlan.find(@plan_id)
    assert_equal "editor", plan.role_of(@colleague.id)
    assert_equal [ @person.id, @colleague.id ].sort, plan.editor_ids.sort
  end

  should "drop a member who leaves, and every member of a deleted plan" do
    @handler.add_member(@plan_id, @colleague.id, role: "viewer")
    @handler.remove_member(@plan_id, @colleague.id)
    assert_equal [ [ @person.id, "editor" ] ], roles

    @handler.delete_plan(@plan_id)
    assert_empty roles
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      @handler.add_member(@plan_id, @colleague.id, role: "viewer")
      @handler.add_member(@plan_id, @colleague.id, role: "editor")
      gone = SecureRandom.uuid_v7
      @handler.create_plan(gone, name: "Gone", base_on: "2026-11-14")
      @handler.delete_plan(gone)

      before = snapshot_read_models(TeamPlanning::Projections::PlanMembers, @tenant)
      assert_equal 2, before[:members].size

      TeamPlanning::Projections::PlanMembers.reset!(tenant: @tenant)
      assert_equal 0, TeamPlanningPlanMember.count
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::PlanMembers, tenant: @tenant)

      assert_equal before, snapshot_read_models(TeamPlanning::Projections::PlanMembers, @tenant)
    end
  end
end
