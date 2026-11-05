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

  context "lifecycle timestamps" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @lens_role = create(:framework_role, name: "Product Manager")
        @enrolled_at = Time.utc(2026, 9, 1, 9)
        @aligned_at = Time.utc(2026, 9, 11, 9)
        AssessmentCycleEnrollment.find_by!(person_id: @report.id).update!(enrolled_at: @enrolled_at)
        AssessmentCycleProgress.find_by!(person_id: @report.id).update!(
          status: "aligned", started_at: Time.utc(2026, 9, 2), self_completed_at: Time.utc(2026, 9, 5),
          manager_completed_at: Time.utc(2026, 9, 8), alignment_started_at: Time.utc(2026, 9, 10),
          alignment_started_by_id: @manager.id, aligned_at: @aligned_at, aligned_by_id: @manager.id,
          aligned_framework_version: 1
        )
        AssessmentCycleRoleAlignment.create!(
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @report.id, framework_id: @cycle.framework_id,
          role_id: @role.role_id, home: true, status: "aligned", alignment_started_at: Time.utc(2026, 9, 10),
          alignment_started_by_id: @manager.id, aligned_at: @aligned_at, aligned_by_id: @manager.id
        )
        AssessmentCycleRoleAlignment.create!(
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @report.id, framework_id: @cycle.framework_id,
          role_id: @lens_role.role_id, home: false, status: "aligning", alignment_started_at: Time.utc(2026, 9, 12),
          alignment_started_by_id: @manager.id, reopened_at: Time.utc(2026, 9, 14), reopened_by_id: @manager.id
        )
      end
    end

    should "say when each milestone happened, and who acted" do
      participant = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, mode: "full" })[:participants].first

      assert_equal "2026-09-01T09:00:00Z", participant[:enrolled_at]
      assert_equal "2026-09-05T00:00:00Z", participant[:self_completed_at]
      assert_equal "2026-09-08T00:00:00Z", participant[:manager_completed_at]
      assert_equal "2026-09-10T00:00:00Z", participant[:alignment_started_at]
      assert_equal "2026-09-11T09:00:00Z", participant[:aligned_at]
      assert_equal({ id: @manager.id, name: "Manager" }, participant[:aligned_by])
      assert_equal 1, participant[:aligned_framework_version]
    end

    should "list every role alignment, home first, with a lens re-open" do
      alignments = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, mode: "full" })
        .dig(:participants, 0, :role_alignments)

      assert_equal [ "Engineer", "Product Manager" ], alignments.map { |a| a[:role_name] }
      assert alignments.first[:home]
      lens = alignments.last
      assert_equal "aligning", lens[:status]
      assert_nil lens[:aligned_at]
      assert_equal "2026-09-14T00:00:00Z", lens[:reopened_at]
      assert_equal({ id: @manager.id, name: "Manager" }, lens[:reopened_by])
    end

    should "report the cycle's dates and the median days to align in summary mode" do
      result = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id })

      assert_equal 10.0, result[:median_days_to_align]
      assert_equal "open", result.dig(:cycle, :status)
      assert_equal @cycle.opened_at.utc.iso8601, result.dig(:cycle, :opened_at)
      assert_nil result.dig(:cycle, :closed_at)
    end

    should "give a skip-level manager the same timestamps" do
      skip_user = create(:user)
      skip_tu = ActsAsTenant.with_tenant(@tenant) do
        skip = create(:person, tenant: @tenant, email: skip_user.email, name: "Skip")
        @manager.update!(manager: skip)
        create(:tenant_user, tenant: @tenant, user: skip_user, person: skip, role: :member)
      end
      ctx = AuthorizationContext.new(user: skip_user, tenant_user: skip_tu, person: skip_tu.person)

      participant = call_op(context: ctx, params: { cycle_id: @cycle.cycle_id, mode: "full" })[:participants].first

      assert_equal "2026-09-11T09:00:00Z", participant[:aligned_at]
    end

    should "give a tenant admin the same timestamps across the whole cycle" do
      admin_user = create(:user)
      admin_tu = ActsAsTenant.with_tenant(@tenant) do
        admin = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
        create(:tenant_user, tenant: @tenant, user: admin_user, person: admin, role: :admin)
      end
      ctx = AuthorizationContext.new(user: admin_user, tenant_user: admin_tu, person: admin_tu.person)

      participant = call_op(context: ctx, params: { cycle_id: @cycle.cycle_id, mode: "full" })[:participants].first

      assert_equal "2026-09-11T09:00:00Z", participant[:aligned_at]
      assert_equal 2, participant[:role_alignments].size
    end

    should "narrow participants to those aligned in an inclusive UTC date window" do
      inside = call_op(context: @manager_ctx,
        params: { cycle_id: @cycle.cycle_id, mode: "full", aligned_from: "2026-09-11", aligned_to: "2026-09-11" })
      before = call_op(context: @manager_ctx,
        params: { cycle_id: @cycle.cycle_id, mode: "full", aligned_to: "2026-09-10" })

      assert_equal [ @report.id ], inside[:participants].map { |p| p[:person_id] }
      assert_empty before[:participants]
      assert_equal 1, before[:total], "the window narrows the list, not the funnel"
    end

    should "keep someone whose lens alignment, not their home one, completed in the window" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleRoleAlignment.find_by!(role_id: @lens_role.role_id)
          .update!(status: "aligned", aligned_at: Time.utc(2026, 9, 20, 12), aligned_by_id: @manager.id)
      end

      result = call_op(context: @manager_ctx,
        params: { cycle_id: @cycle.cycle_id, mode: "full", aligned_from: "2026-09-20", aligned_to: "2026-09-20" })

      assert_equal [ @report.id ], result[:participants].map { |p| p[:person_id] }
    end

    should "show no framework version once a re-join has cleared the alignment" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleProgress.find_by!(person_id: @report.id).update!(status: "in_progress", aligned_at: nil, aligned_by_id: nil)
      end

      participant = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, mode: "full" })[:participants].first

      assert_nil participant[:aligned_framework_version]
    end

    should "load role alignments only when asked, so the web views don't pay for them" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_empty Reporting::CycleCohort.new(cycle: @cycle).call.participants.first.role_alignments
        assert_equal 2, Reporting::CycleCohort.new(cycle: @cycle, include_role_alignments: true)
          .call.participants.first.role_alignments.size
      end
    end

    should "refuse a date in any shape but YYYY-MM-DD" do
      [ "2026-09-11T23:00:00+10:00", "20260911", "2026-W37-5" ].each do |value|
        assert_raises(Operations::Base::ParameterError, value) do
          call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, mode: "full", aligned_from: value })
        end
      end
    end

    should "refuse a window outside full mode, or one that isn't a date" do
      assert_raises(Operations::Base::ParameterError) do
        call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, aligned_from: "2026-09-01" })
      end
      assert_raises(Operations::Base::ParameterError) do
        call_op(context: @manager_ctx,
          params: { cycle_id: @cycle.cycle_id, mode: "summary", aligned_from: "2026-09-01" })
      end
      assert_raises(Operations::Base::ParameterError) do
        call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, mode: "full", aligned_from: "2026-13-01" })
      end
      assert_raises(Operations::Base::ParameterError) do
        call_op(context: @manager_ctx,
          params: { cycle_id: @cycle.cycle_id, mode: "full", aligned_from: "2026-09-12", aligned_to: "2026-09-11" })
      end
    end
  end

  should "let an admin see the whole cycle, or narrow to their own subtree" do
    admin_user = create(:user)
    admin_tu = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
      create(:tenant_user, tenant: @tenant, user: admin_user, person: person, role: :admin)
    end
    ctx = AuthorizationContext.new(user: admin_user, tenant_user: admin_tu, person: admin_tu.person)

    whole = call_op(context: ctx, params: { cycle_id: @cycle.cycle_id })
    assert_equal 1, whole[:total]

    # Admin manages nobody → "mine" scopes to an empty subtree.
    mine = call_op(context: ctx, params: { cycle_id: @cycle.cycle_id, scope: "mine" })
    assert_equal 0, mine[:total]
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
