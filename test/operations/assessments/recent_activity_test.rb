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
  def member_ctx(name, role: :member)
    user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: user.email, name: name)
      yield person if block_given?
      tu = create(:tenant_user, tenant: @tenant, user: user, person: person, role: role)
      AuthorizationContext.new(user: user, tenant_user: tu, person: person)
    end
  end

  def add_evidence(person, at:)
    create(:evidence_item, tenant: @tenant, person_id: person.id, framework_id: @framework_id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2, recorded_at: at)
  end

  context "scope and person_id" do
    should "give a skip-level manager their whole org's activity" do
      skip_ctx = member_ctx("Skip") { |skip| @manager.update!(manager: skip) }

      assert_equal [ "Ada" ], call_op(context: skip_ctx)[:activity].map { |i| i.dig(:person, :name) }
    end

    should "narrow to one person, and refuse one outside the caller's org" do
      outsider = create(:person, tenant: @tenant, name: "Elsewhere")
      add_evidence(outsider, at: 1.minute.ago)

      assert_equal [ "Ada" ], call_op(context: @manager_ctx, params: { person_id: @report.id })[:activity]
        .map { |i| i.dig(:person, :name) }
      assert_raises(Pundit::NotAuthorizedError) { call_op(context: @manager_ctx, params: { person_id: outsider.id }) }
    end

    should "let a rating delegate outside the org name the person they rate" do
      delegate_ctx = member_ctx("Dana") do |delegate|
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
          delegate_person_id: delegate.id, granted_by_id: @manager.id)
      end

      activity = call_op(context: delegate_ctx, params: { person_id: @report.id })[:activity]

      assert_equal [ "Ada" ], activity.map { |i| i.dig(:person, :name) }
    end

    should "show a delegate only the framework they were delegated, not the person's others" do
      other_framework = SecureRandom.uuid_v7
      create(:person_framework_assignment, tenant: @tenant, person_id: @report.id, framework_id: other_framework)
      create(:evidence_item, tenant: @tenant, person_id: @report.id, framework_id: other_framework,
        capability_stable_id: @cap.stable_id, level_ordinal: 1, recorded_at: 1.minute.ago)
      create(:person_development_comment, tenant: @tenant, person_id: @report.id, framework_id: other_framework,
        capability_stable_id: @cap.stable_id, level_ordinal: 1, posted_at: 30.seconds.ago, body: "Private note")
      delegate_ctx = member_ctx("Dana") do |delegate|
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
          delegate_person_id: delegate.id, granted_by_id: @manager.id)
      end

      activity = call_op(context: delegate_ctx, params: { person_id: @report.id })[:activity]

      assert_equal [ @framework_id ], activity.map { |i| i[:framework_id] }.uniq
      refute(activity.any? { |i| i[:detail] == "Private note" })
    end

    should "let a tenant admin name anyone" do
      outsider = create(:person, tenant: @tenant, name: "Elsewhere")
      add_evidence(outsider, at: 1.minute.ago)

      activity = call_op(context: member_ctx("Admin", role: :admin), params: { person_id: outsider.id })[:activity]

      assert_equal [ "Elsewhere" ], activity.map { |i| i.dig(:person, :name) }
    end
  end

  context "window, cycle and kinds" do
    should "return what is in the window even when newer activity exists" do
      add_evidence(@report, at: Time.utc(2026, 9, 10, 12))

      activity = call_op(context: @manager_ctx, params: { since: "2026-09-10", until: "2026-09-10", limit: 1 })[:activity]

      assert_equal [ "2026-09-10T12:00:00Z" ], activity.map { |i| i[:occurred_at] }
    end

    should "keep one cycle's activity and leave out comments, which carry no cycle" do
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      create(:evidence_item, tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, recorded_at: 1.minute.ago, cycle_id: cycle.cycle_id)
      create(:person_development_comment, tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, posted_at: 30.seconds.ago)

      activity = call_op(context: @manager_ctx, params: { cycle_id: cycle.cycle_id })[:activity]

      assert_equal [ "evidence_recorded" ], activity.map { |i| i[:kind] }
    end

    should "return nothing for an empty kinds list and refuse an unknown kind" do
      assert_empty call_op(context: @manager_ctx, params: { kinds: [] })[:activity]
      assert_raises(Operations::Base::ParameterError) { call_op(context: @manager_ctx, params: { kinds: %w[rated] }) }
    end

    should "refuse a time it can't read, a date-time with no offset, and a window that ends before it starts" do
      [ { since: "last week" }, { since: "2026-09-10T09:00:00" }, { since: "2026-10-01", until: "2026-09-01" } ].each do |window|
        assert_raises(Operations::Base::ParameterError, window.inspect) { call_op(context: @manager_ctx, params: window) }
      end
    end
  end

  context "alignment milestones" do
    setup do
      @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      @lens_role = create(:framework_role, name: "Product Manager", code: "P")
      AssessmentCycleRoleAlignment.create!(
        tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @report.id, framework_id: @framework_id,
        role_id: @lens_role.role_id, home: false, status: "aligning", alignment_started_at: 2.minutes.ago,
        alignment_started_by_id: @manager.id, reopened_at: 1.minute.ago, reopened_by_id: @manager.id
      )
    end

    should "include a lens alignment and its re-open, with the role" do
      activity = call_op(context: @manager_ctx, params: { kinds: %w[alignment_started alignment_reopened] })[:activity]

      assert_equal %w[alignment_reopened alignment_started], activity.map { |i| i[:kind] }
      assert_equal [ "P", "Product Manager", false ], activity.first.values_at(:role_code, :role_name, :home)
    end

    should "read one person's completions from the stream, re-opened ones included" do
      stream = EventStreamNaming.person_development_stream(@report.id, @framework_id)
      [ PersonDevelopment::Events::FullAlignmentCompleted, PersonDevelopment::Events::AlignmentReopened,
        PersonDevelopment::Events::FullAlignmentCompleted ].each do |event_class|
        Rails.configuration.event_store.append(
          event_class.new(data: { cycle_id: @cycle.cycle_id, completed_by_id: @manager.id, reopened_by_id: @manager.id },
                          metadata: { tenant_id: @tenant.id, person_id: @report.id, framework_id: @framework_id }),
          stream_name: stream
        )
      end

      activity = call_op(context: @manager_ctx,
        params: { person_id: @report.id, kinds: %w[alignment_completed alignment_reopened] })[:activity]

      assert_equal %w[alignment_completed alignment_reopened alignment_completed], activity.map { |i| i[:kind] }
      assert(activity.all? { |i| i[:home] })
    end
  end
end
