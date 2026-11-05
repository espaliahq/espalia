# frozen_string_literal: true

require "test_helper"

class Operations::Assessments::TimelineTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan")
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @person = create(:person, tenant: @tenant, name: "Alice", manager: @manager)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      @pd = PersonDevelopment::CommandHandler.new
      @pd.assign_to_framework(@person.id, @framework_id, @role.role_id, @level.level_id)
      @cycle_id = SecureRandom.uuid_v7
      cycles = AssessmentCycles::CommandHandler.new
      cycles.define_cycle(@cycle_id, @framework_id, "H2", "regular", 1, defined_by: @manager.id)
      cycles.enroll(@cycle_id, @person.id, enrolled_by: @manager.id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
  end

  def call_op(context: @manager_ctx, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::Timeline.call(context: context, params: { assignment_id: @assignment.id, **params })
    end
  end

  def with_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def append_historical(event_class, data, actor_id: nil)
    with_tenant do
      Rails.configuration.event_store.append(
        event_class.new(data: data, metadata: { tenant_id: @tenant.id, person_id: @person.id,
                                                framework_id: @framework_id, actor_id: actor_id }.compact),
        stream_name: EventStreamNaming.person_development_stream(@person.id, @framework_id)
      )
    end
  end

  should "keep every completion and re-open the read models overwrite" do
    with_tenant do
      @pd.start_alignment(@person.id, @framework_id, @cycle_id, started_by_id: @manager.id)
      @pd.complete_alignment(@person.id, @framework_id, @cycle_id, completed_by_id: @manager.id)
      @pd.reopen_alignment(@person.id, @framework_id, @cycle_id, reopened_by_id: @manager.id)
      @pd.complete_alignment(@person.id, @framework_id, @cycle_id, completed_by_id: @manager.id)
    end

    milestones = call_op(kinds: %w[alignment_started alignment_completed alignment_reopened])[:milestones]

    assert_equal %w[alignment_started alignment_completed alignment_reopened alignment_completed], milestones.map { |m| m[:kind] }
    assert(milestones.all? { |m| m[:actor] == { id: @manager.id, name: "Morgan" } })
    assert(milestones.all? { |m| m[:home] && m[:role_code] == "E" && m[:role_name] == "SWE" && m.dig(:cycle, :name) == "H2" })
    assert_equal 1, milestones.second[:framework_version]
  end

  should "start with the assignment, then the join, in occurrence order" do
    milestones = call_op[:milestones]

    assert_equal %w[assigned_to_framework joined_cycle], milestones.first(2).map { |m| m[:kind] }
    assert_equal({ id: @role.role_id, code: "E", name: "SWE" }, milestones.first[:role])
    assert_equal milestones.map { |m| m[:occurred_at] }.sort, milestones.map { |m| m[:occurred_at] }
  end

  should "read a historical alignment with no role or actor as the home role's, by the metadata actor" do
    append_historical(PersonDevelopment::Events::FullAlignmentCompleted, { cycle_id: @cycle_id }, actor_id: @manager.id)

    milestone = call_op(kinds: %w[alignment_completed])[:milestones].sole

    assert milestone[:home]
    assert_equal @role.role_id, milestone[:role_id]
    assert_equal({ id: @manager.id, name: "Morgan" }, milestone[:actor])
  end

  should "name a lens role's alignment as not home" do
    lens_role = with_tenant { create(:framework_role, role_family_id: @role.role_family_id, name: "PM", code: "P") }
    append_historical(PersonDevelopment::Events::AlignmentStarted,
      { cycle_id: @cycle_id, started_by_id: @manager.id, role_id: lens_role.role_id, level_ordinal: 3 })

    milestone = call_op(kinds: %w[alignment_started])[:milestones].sole

    refute milestone[:home]
    assert_equal [ lens_role.role_id, "P", "PM" ], milestone.values_at(:role_id, :role_code, :role_name)
    assert_equal 3, milestone[:level_ordinal]
  end

  should "carry the latest self-assessment completion as derived" do
    with_tenant do
      AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id)
        .update!(self_completed_at: Time.utc(2026, 9, 5))
    end

    milestone = call_op(kinds: %w[self_assessment_completed])[:milestones].sole

    assert milestone[:derived]
    assert_equal "2026-09-05T00:00:00Z", milestone[:occurred_at]
    assert_nil milestone[:actor]
  end

  should "include the reporting manager, delegations and explorations, with who they name" do
    delegate = with_tenant { create(:person, tenant: @tenant, name: "Dana") }
    with_tenant do
      @pd.record_reporting_manager(@person.id, @framework_id, @manager.id)
      @pd.delegate_manager_rating(@person.id, @framework_id, delegate.id, granted_by_id: @manager.id)
    end

    by_kind = call_op[:milestones].index_by { |m| m[:kind] }

    assert_equal({ id: @manager.id, name: "Morgan" }, by_kind["reporting_manager_recorded"][:manager])
    assert_equal({ id: delegate.id, name: "Dana" }, by_kind["manager_rating_delegated"][:delegate])
    assert_equal({ id: @manager.id, name: "Morgan" }, by_kind["manager_rating_delegated"][:actor])
  end

  should "narrow to one cycle" do
    other_cycle = SecureRandom.uuid_v7
    append_historical(PersonDevelopment::Events::AlignmentStarted, { cycle_id: other_cycle, started_by_id: @manager.id })

    cycle_ids = call_op(cycle_id: @cycle_id)[:milestones].map { |m| m.dig(:cycle, :id) }.uniq

    assert_equal [ @cycle_id ], cycle_ids
  end

  should "keep the home role fixed at the join when the role changes mid-cycle" do
    pm = with_tenant { create(:framework_role, role_family_id: @role.role_family_id, name: "PM", code: "P") }
    pm_level = with_tenant { create(:framework_level, role_id: pm.role_id, ordinal: 2, title: "PM2", code: "P2") }
    with_tenant do
      @pd.change_person_role(@person.id, @framework_id, pm.role_id, pm_level.level_id, changed_by: @manager.id)
      assert_equal pm.role_id, AssessmentCycleEnrollment.find_by!(cycle_id: @cycle_id, person_id: @person.id).role_id,
        "the enrollment follows the change; the timeline must not"
    end
    append_historical(PersonDevelopment::Events::FullAlignmentCompleted, { cycle_id: @cycle_id }, actor_id: @manager.id)

    milestone = call_op(kinds: %w[alignment_completed])[:milestones].sole

    assert milestone[:home]
    assert_equal @role.role_id, milestone[:role_id]
  end

  should "return nothing for an empty kinds list" do
    assert_empty call_op(kinds: [])[:milestones]
  end

  should "show free-text reasons to the manager chain and withhold them from the assessee" do
    assessee_user = create(:user)
    assessee_tu = with_tenant do
      @person.update!(email: assessee_user.email)
      create(:tenant_user, tenant: @tenant, user: assessee_user, person: @person, role: :member)
    end
    assessee_ctx = AuthorizationContext.new(user: assessee_user, tenant_user: assessee_tu, person: @person)
    append_historical(PersonDevelopment::Events::LeftAssessmentCycle, { cycle_id: @cycle_id, reason: "Moving teams" })

    assert_equal "Moving teams", call_op(kinds: %w[left_cycle])[:milestones].sole[:reason]
    refute call_op(context: assessee_ctx, kinds: %w[left_cycle])[:milestones].sole.key?(:reason)
  end

  should "report a delegation's expiry in the same format as every other time" do
    delegate = with_tenant { create(:person, tenant: @tenant, name: "Dana") }
    with_tenant do
      @pd.delegate_manager_rating(@person.id, @framework_id, delegate.id, granted_by_id: @manager.id,
                                  expires_at: Time.utc(2026, 12, 1, 9, 30))
    end

    milestone = call_op(kinds: %w[manager_rating_delegated])[:milestones].sole

    assert_equal "2026-12-01T09:30:00Z", milestone[:expires_at]
  end

  should "refuse a kind it doesn't know" do
    assert_raises(Operations::Base::ParameterError) { call_op(kinds: %w[alignment_finished]) }
  end

  should "deny someone outside the chain" do
    outsider_user = create(:user)
    outsider_tu = with_tenant do
      outsider = create(:person, tenant: @tenant, email: outsider_user.email, name: "Outsider")
      create(:tenant_user, tenant: @tenant, user: outsider_user, person: outsider, role: :member)
    end
    outsider_ctx = AuthorizationContext.new(user: outsider_user, tenant_user: outsider_tu, person: outsider_tu.person)

    assert_raises(Pundit::NotAuthorizedError) { call_op(context: outsider_ctx) }
  end
end
