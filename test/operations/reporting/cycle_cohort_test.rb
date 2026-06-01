# frozen_string_literal: true

require "test_helper"

class Operations::Reporting::CycleCohortTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      framework_id = SecureRandom.uuid_v7
      @role = create(:framework_role, name: "Engineer")
      category = create(:framework_capability_category, framework_id: framework_id)
      cap = create(:framework_capability, category_id: category.category_id)
      create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: @role.role_id)

      @cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1 2026",
        framework_id: framework_id, status: "open")

      @manager_user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report One", manager: @manager)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
        person_id: @report.id, role_id: @role.role_id, level_ordinal: 2, status: "enrolled")
      create(:assessment_cycle_progress, tenant: @tenant, cycle: @cycle,
        person_id: @report.id, status: "started")
    end
    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
  end

  def call_op(context:, params:)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Reporting::CycleCohort.call(context: context, params: params)
    end
  end

  should "return funnel + counts in summary mode without participants" do
    result = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id })

    assert_equal 1, result[:total]
    assert_equal 1, result.dig(:funnel, :enrolled)
    assert_empty result[:participants]
    assert_empty result[:groups]
  end

  should "include per-participant progress in full mode (no rating values)" do
    result = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, mode: "full" })

    assert_equal 1, result[:participants].size
    participant = result[:participants].first
    assert_equal "Report One", participant[:name]
    # Privacy: progress flags only, never frequencies/scores.
    refute participant.key?(:self_rated_frequency)
    assert_includes participant.keys, :self_done
  end

  should "let an admin see the whole cycle" do
    admin_user = create(:user)
    admin_tu = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
      create(:tenant_user, tenant: @tenant, user: admin_user, person: person, role: :admin)
    end
    ctx = AuthorizationContext.new(user: admin_user, tenant_user: admin_tu, person: admin_tu.person)

    result = call_op(context: ctx, params: { cycle_id: @cycle.cycle_id })
    assert_equal 1, result[:total]
  end

  should "deny a member with no reports in the cycle" do
    outsider_user = create(:user)
    outsider_tu = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: outsider_user.email, name: "Outsider")
      create(:tenant_user, tenant: @tenant, user: outsider_user, person: person, role: :member)
    end
    ctx = AuthorizationContext.new(user: outsider_user, tenant_user: outsider_tu, person: outsider_tu.person)

    assert_raises(Pundit::NotAuthorizedError) do
      call_op(context: ctx, params: { cycle_id: @cycle.cycle_id })
    end
  end
end
