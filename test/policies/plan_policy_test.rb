# frozen_string_literal: true

require "test_helper"

class PlanPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @editor = create(:person, tenant: @tenant)
    @viewer = create(:person, tenant: @tenant)
    [ @editor, @viewer ].each { |person| create(:tenant_user, tenant: @tenant, person:) }
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(SecureRandom.uuid_v7, name: "Next year", base_on: "2026-11-14", created_by_id: @editor.id)
    @plan.add_member(@viewer.id, role: "viewer", added_by_id: @editor.id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "an editor" do
    setup { @policy = PlanPolicy.new(context_for(@editor), @plan) }

    should "open, change and delete the plan, choose its members, and leave it" do
      assert @policy.show?
      assert @policy.update?
      assert @policy.destroy?
      assert @policy.manage_members?
      assert @policy.leave?
    end

    should "not create a plan while only a member" do
      assert_not PlanPolicy.new(context_for(@editor), nil).create?
    end
  end

  context "a viewer" do
    setup { @policy = PlanPolicy.new(context_for(@viewer), @plan) }

    should "open the plan and leave it, and do nothing else" do
      assert @policy.show?
      assert @policy.leave?
      assert_not @policy.update?
      assert_not @policy.destroy?
      assert_not @policy.manage_members?
    end
  end

  context "a member who has left or been forgotten" do
    should "lose the plan at once" do
      @editor.update!(status: "inactive")
      @viewer.update_columns(forgotten_at: Time.current, name: "Former member")

      [ @editor, @viewer ].each do |person|
        policy = PlanPolicy.new(context_for(person), @plan)
        assert_not policy.show?
        assert_not policy.leave?
        assert_not policy.update?
      end
    end
  end

  context "someone the plan doesn't name" do
    should "get nothing from it, as a tenant admin, an Org Graph editor, a planner or a global admin" do
      outsider = create(:person, tenant: @tenant)
      [ context_for(outsider, role: :admin), context_for(outsider, org_graph_editor: true),
        context_for(outsider, team_planner: true), context_for(outsider, global_admin: true),
        context_for(outsider) ].each do |context|
        policy = PlanPolicy.new(context, @plan)
        %i[show? update? destroy? manage_members? leave? destroy_frozen? see_pay? manage_see_pay? restore_see_pay? upload_pay?].each do |predicate|
          assert_not policy.public_send(predicate), predicate
        end
      end
    end
  end

  context "#create?" do
    should "admit a tenant admin and a planner, and nobody else" do
      person = create(:person, tenant: @tenant)
      assert PlanPolicy.new(context_for(person, role: :admin), nil).create?
      assert PlanPolicy.new(context_for(person, team_planner: true), nil).create?
      assert_not PlanPolicy.new(context_for(person, org_graph_editor: true), nil).create?
      assert_not PlanPolicy.new(context_for(person), nil).create?
    end

    should "refuse an admin or a planner who has left, whose plan nobody could open" do
      person = create(:person, tenant: @tenant, status: "inactive")
      assert_not PlanPolicy.new(context_for(person, role: :admin), nil).create?
      assert_not PlanPolicy.new(context_for(person, team_planner: true), nil).create?
    end
  end

  context "a frozen plan" do
    setup { @editor.update!(status: "inactive") }

    should "be frozen once no editor is still active and remembered" do
      assert PlanPolicy.frozen?(@plan)
      @editor.update!(status: "active")
      assert_not PlanPolicy.frozen?(@plan)
    end

    should "be frozen once its only editor has no account here, though still active" do
      @editor.update!(status: "active")
      TenantUser.where(person: @editor).update_all(forgotten_at: Time.current)
      assert PlanPolicy.frozen?(@plan)
    end

    should "let a tenant admin delete it, and still not open it" do
      policy = PlanPolicy.new(context_for(create(:person, tenant: @tenant), role: :admin), @plan)
      assert policy.destroy_frozen?
      assert_not policy.show?
    end

    should "stay readable to its viewers and changeable by nobody" do
      policy = PlanPolicy.new(context_for(@viewer), @plan)
      assert policy.show?
      assert_not policy.update?
      assert_not policy.manage_members?
      assert_not policy.destroy_frozen?
    end

    should "be out of a tenant admin's reach while an editor remains" do
      @editor.update!(status: "active")
      assert_not PlanPolicy.new(context_for(create(:person, tenant: @tenant), role: :admin), @plan).destroy_frozen?
    end
  end

  context "the see-pay right" do
    should "let its holder see pay and pass it on, and a member without it neither" do
      holder = PlanPolicy.new(context_for(@editor), @plan)
      assert holder.see_pay?
      assert holder.manage_see_pay?

      viewer = PlanPolicy.new(context_for(@viewer), @plan)
      assert_not viewer.see_pay?
      assert_not viewer.manage_see_pay?
    end

    should "follow a grant, for a viewer as for an editor" do
      @plan.grant_see_pay(@viewer.id, granted_by_id: @editor.id)
      assert PlanPolicy.new(context_for(@viewer), @plan).see_pay?
    end

    should "answer the same from the plan's row as from its stream" do
      row = TeamPlanningPlan.new(id: @plan.plan_id, tenant: @tenant)
      row.members.build(person_id: @editor.id, role: "editor", see_pay: true, tenant: @tenant)
      row.members.build(person_id: @viewer.id, role: "viewer", tenant: @tenant)

      assert PlanPolicy.new(context_for(@editor), row).see_pay?
      assert_not PlanPolicy.new(context_for(@viewer), row).see_pay?
      assert_equal [ @editor.id ], row.pay_holder_ids
    end

    should "let only an editor who holds it upload pay" do
      assert PlanPolicy.new(context_for(@editor), @plan).upload_pay?
      @plan.grant_see_pay(@viewer.id, granted_by_id: @editor.id)
      assert_not PlanPolicy.new(context_for(@viewer), @plan).upload_pay?

      other = create(:person, tenant: @tenant)
      create(:tenant_user, tenant: @tenant, person: other)
      @plan.add_member(other.id, role: "editor", added_by_id: @editor.id)
      assert_not PlanPolicy.new(context_for(other), @plan).upload_pay?
    end

    should "leave a holder who has left with nothing" do
      @editor.update!(status: "inactive")
      assert_not PlanPolicy.new(context_for(@editor), @plan).see_pay?
    end
  end

  context "a plan locked out of pay" do
    setup do
      @plan.add_member(@viewer.id, role: "editor", added_by_id: @editor.id)
      @admin = context_for(create(:person, tenant: @tenant), role: :admin)
    end

    should "be locked out once no holder is still active and remembered" do
      assert_not PlanPolicy.locked_out?(@plan)
      @editor.update!(status: "inactive")
      assert PlanPolicy.locked_out?(@plan)
    end

    should "let a tenant admin restore it while an editor remains, and still not open it" do
      @editor.update!(status: "inactive")
      policy = PlanPolicy.new(@admin, @plan)
      assert policy.restore_see_pay?
      assert_not policy.show?
      assert_not policy.see_pay?
    end

    should "be out of a tenant admin's reach while a holder remains, or once frozen" do
      assert_not PlanPolicy.new(@admin, @plan).restore_see_pay?
      [ @editor, @viewer ].each { it.update!(status: "inactive") }
      assert_not PlanPolicy.new(@admin, @plan).restore_see_pay?
    end

    should "be out of reach of anyone but a tenant admin" do
      @editor.update!(status: "inactive")
      [ context_for(@viewer), context_for(create(:person, tenant: @tenant), team_planner: true) ].each do |context|
        assert_not PlanPolicy.new(context, @plan).restore_see_pay?
      end
    end
  end

  context "Scope" do
    should "agree with show? for members, leavers and outsiders" do
      plan_id = SecureRandom.uuid_v7
      admin = create(:person, tenant: @tenant)
      handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor, role: :admin))
      handler.create_plan(plan_id, name: "Next year", base_on: "2026-11-14")
      handler.add_member(plan_id, @viewer.id, role: "viewer")
      @editor.update!(status: "inactive")

      [ @editor, @viewer, admin ].each do |person|
        [ :member, :admin ].each do |role|
          context = context_for(person, role:)
          listed = PlanPolicy::Scope.new(context, TeamPlanningPlan).resolve.pluck(:id)
          shown = PlanPolicy.new(context, TeamPlanningPlan.includes(:members).find(plan_id)).show?
          assert_equal shown, listed.include?(plan_id), "#{person.id} as #{role}"
        end
      end
      assert_equal [ plan_id ], PlanPolicy::Scope.new(context_for(@viewer), TeamPlanningPlan).resolve.pluck(:id)
    end
  end

  context "someone outside the tenant" do
    should "do nothing" do
      policy = PlanPolicy.new(AuthorizationContext.new(user: create(:user), tenant_user: nil, person: @editor), @plan)
      assert_not policy.create?
      assert_not policy.show?
      assert_not policy.update?
      assert_not policy.manage_frozen?
    end
  end

  private

  def context_for(person, role: :member, global_admin: false, **grants)
    user = create(:user, global_admin:)
    AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, person:, role:, **grants), person:)
  end
end
