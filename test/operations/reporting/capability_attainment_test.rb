# frozen_string_literal: true

require "test_helper"

class Operations::Reporting::CapabilityAttainmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      framework_id = SecureRandom.uuid_v7
      family = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role, name: "Engineer", role_family_id: family.role_family_id)
      (1..3).each { |ordinal| create(:framework_level, role_id: @role.role_id, ordinal: ordinal, code: "E#{ordinal}") }
      category = create(:framework_capability_category, framework_id: framework_id, name: "Thinking")
      @cap = create(:framework_capability, category_id: category.category_id, name: "Strategic Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: @role.role_id)

      @cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1 2026",
        framework_id: framework_id, status: "open")

      @manager_user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report One", manager: @manager)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
        person_id: @report.id, role_id: @role.role_id, level_ordinal: 2, status: "enrolled")
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
        person_id: @report.id, framework_id: framework_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        self_rated_frequency: "consistent")
    end
    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
  end

  def call_op(context:, params:)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Reporting::CapabilityAttainment.call(context: context, params: params)
    end
  end

  def admin_ctx
    admin_user = create(:user)
    admin_tu = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
      create(:tenant_user, tenant: @tenant, user: admin_user, person: person, role: :admin)
    end
    AuthorizationContext.new(user: admin_user, tenant_user: admin_tu, person: admin_tu.person)
  end

  should "return unsuppressed aggregates for an admin" do
    result = call_op(context: admin_ctx, params: { cycle_id: @cycle.cycle_id })

    assert_equal 1, result[:total_people]
    assert_nil result[:suppression_floor]
    cell = result[:roles].first[:cells][@cap.stable_id]
    assert_equal 100, cell[:at_or_above_pct]
    assert_equal 1, cell[:at]
    assert_equal 1, cell[:n_assessed]
    assert_not cell[:suppressed]
    assert_equal "Engineering", result[:families].first[:label]
  end

  should "suppress small cohorts for a subtree-scoped manager" do
    result = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id })

    assert_equal Reporting::CapabilityAttainment::MIN_COHORT, result[:suppression_floor]
    cell = result[:roles].first[:cells][@cap.stable_id]
    assert cell[:suppressed]
    assert_nil cell[:at_or_above_pct]
    assert_nil cell[:at]
    assert_equal 1, cell[:n_in_group]
    assert_equal 1, cell[:n_assessed]
  end

  should "honour the perspective parameter" do
    result = call_op(context: admin_ctx,
      params: { cycle_id: @cycle.cycle_id, perspective: "manager" })

    assert_equal "manager_only", result[:perspective]
    cell = result[:roles].first[:cells][@cap.stable_id]
    # No manager ratings exist → unassessed under that perspective.
    assert_equal 0, cell[:n_assessed]
    assert_equal 0, cell[:at_or_above_pct]
  end

  should "let an admin narrow to their own subtree via scope" do
    mine = call_op(context: admin_ctx, params: { cycle_id: @cycle.cycle_id, scope: "mine" })

    # Admin manages nobody → empty subtree.
    assert_equal 0, mine[:total_people]
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
