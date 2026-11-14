# frozen_string_literal: true

require "test_helper"

class PlanPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @editor = create(:person, tenant: @tenant)
    @viewer = create(:person, tenant: @tenant)
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
        %i[show? update? destroy? manage_members? leave? destroy_frozen?].each do |predicate|
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
  end

  context "a frozen plan" do
    setup { @editor.update!(status: "inactive") }

    should "be frozen once no editor is still active and remembered" do
      assert PlanPolicy.frozen?(@plan)
      @editor.update!(status: "active")
      assert_not PlanPolicy.frozen?(@plan)
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
