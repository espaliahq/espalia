# frozen_string_literal: true

require "test_helper"

class Operations::Assessments::RecentActivityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    category = create(:framework_capability_category, framework_id: @framework_id)
    @cap = create(:framework_capability, category_id: category.category_id, name: "Strategic Thinking")

    @manager_user = create(:user)
    @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Boss")
    @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
    @report = create(:person, tenant: @tenant, name: "Ada", manager: @manager)
    create(:person_framework_assignment, tenant: @tenant, person_id: @report.id, framework_id: @framework_id)
    create(:evidence_item,
      tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2, recorded_at: Time.current)

    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def call_op(context:, params: {})
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::RecentActivity.call(context: context, params: params)
    end
  end

  should "return a manager's direct reports' activity" do
    result = call_op(context: @manager_ctx)

    activity = result[:activity]
    assert_equal 1, activity.size
    item = activity.first
    assert_equal "evidence_recorded", item[:kind]
    assert_equal "Ada", item.dig(:person, :name)
    assert_equal "Strategic Thinking", item.dig(:capability, :name)
    refute item.key?(:frequency)
  end

  should "return an IC's own activity" do
    ic_user = create(:user)
    ic_ctx = ActsAsTenant.with_tenant(@tenant) do
      ic = create(:person, tenant: @tenant, email: ic_user.email, name: "Solo")
      tu = create(:tenant_user, tenant: @tenant, user: ic_user, person: ic, role: :member)
      create(:person_framework_assignment, tenant: @tenant, person_id: ic.id, framework_id: @framework_id)
      create(:evidence_item,
        tenant: @tenant, person_id: ic.id, framework_id: @framework_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 1, recorded_at: Time.current)
      AuthorizationContext.new(user: ic_user, tenant_user: tu, person: ic)
    end

    result = call_op(context: ic_ctx)
    assert_equal [ "Solo" ], result[:activity].map { |i| i.dig(:person, :name) }
  end

  should "respect the limit" do
    ActsAsTenant.with_tenant(@tenant) do
      2.times do
        create(:evidence_item,
          tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2, recorded_at: Time.current)
      end
    end

    assert_equal 1, call_op(context: @manager_ctx, params: { limit: 1 })[:activity].size
  end

  should "deny a caller with no linked person" do
    ctx = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)
    assert_raises(Pundit::NotAuthorizedError) { call_op(context: ctx) }
  end
end
