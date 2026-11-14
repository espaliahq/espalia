# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::PlanWritesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
    end
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def plan(id) = ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find_by(id:) }

  def create_plan(**params) = call(Operations::TeamPlanning::CreatePlan, name: "Next year", **params)

  context "CreatePlan" do
    should "create a plan on the day given, with the caller as its creator" do
      result = create_plan(name: " Next year ", base_on: "2026-07-01")

      assert_equal({ plan_id: result[:plan_id], name: "Next year", base_on: "2026-07-01" }, result)
      assert_equal @admin.person.id, plan(result[:plan_id]).created_by_id
    end

    should "stand the plan on today by default" do
      assert_equal Date.current.iso8601, create_plan[:base_on]
    end

    should "refuse a bad date" do
      %w[next-tuesday 2026-W46 2026-318 20261114].each do |base_on|
        error = assert_raises(Operations::Base::ParameterError, base_on) { create_plan(base_on:) }
        assert_equal "base_on must be a date, YYYY-MM-DD", error.message
      end
    end

    should "refuse a member who is not a tenant admin" do
      assert_raises(Pundit::NotAuthorizedError) { create_plan(as: @member) }
    end
  end

  context "RenamePlan" do
    setup { @plan_id = create_plan[:plan_id] }

    should "rename the creator's plan" do
      result = call(Operations::TeamPlanning::RenamePlan, plan_id: @plan_id, name: "Second half")

      assert_equal({ plan_id: @plan_id, name: "Second half" }, result)
      assert_equal "Second half", plan(@plan_id).name
    end

    should "read as missing to another admin" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::RenamePlan, as: @other_admin, plan_id: @plan_id, name: "Mine now")
      end
      assert_equal "No such plan", error.message
    end

    should "say when no plan has that id" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::RenamePlan, plan_id: SecureRandom.uuid_v7, name: "Ghost")
      end
      assert_equal "No such plan", error.message
    end

    should "refuse a plan id that is not a UUID" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::RenamePlan, plan_id: "next-year", name: "Ghost")
      end
    end
  end

  context "DeletePlan" do
    setup { @plan_id = create_plan[:plan_id] }

    should "delete the creator's plan" do
      assert_equal({ plan_id: @plan_id, deleted: true }, call(Operations::TeamPlanning::DeletePlan, plan_id: @plan_id))
      assert_nil plan(@plan_id)
    end

    should "refuse to change a deleted plan" do
      call(Operations::TeamPlanning::DeletePlan, plan_id: @plan_id)

      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::RenamePlan, plan_id: @plan_id, name: "Back again")
      end
      assert_equal "Next year has been deleted", error.message
    end

    should "read as missing to another admin" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::DeletePlan, as: @other_admin, plan_id: @plan_id)
      end
      assert plan(@plan_id)
    end
  end
end
