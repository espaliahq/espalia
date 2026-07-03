# frozen_string_literal: true

require "test_helper"

class AssessmentCyclePolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @cycle = create(:assessment_cycle, tenant: @tenant)
    end
  end

  context "as a non-member (no tenant_user)" do
    setup do
      @user = create(:user)
      @context = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "deny every action" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      refute policy.index?
      refute policy.show?
      refute policy.define?
      refute policy.enroll?
      refute policy.unenroll?
      refute policy.close?
      refute policy.update?
      refute policy.cohort?
      refute policy.cohort_full_access?
      refute policy.attainment?
    end
  end

  context "as a tenant member" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :member)
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "permit show" do
      assert AssessmentCyclePolicy.new(@context, @cycle).show?
    end

    should "deny index and mutation actions" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      refute policy.index?
      refute policy.define?
      refute policy.enroll?
      refute policy.unenroll?
      refute policy.close?
      refute policy.update?
    end

    should "deny the cohort and attainment views when they have no reports in the cycle" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      ActsAsTenant.with_tenant(@tenant) do
        refute policy.cohort?
        refute policy.cohort_full_access?
        refute policy.attainment?
      end
    end
  end

  context "as a manager with a report in the cycle" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :member)
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant)
        @tenant_user.update!(person: @manager)
        report = create(:person, tenant: @tenant, manager: @manager)
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: report.id, status: "enrolled")
      end
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @manager)
    end

    should "permit the cohort and attainment views but not full access or mutations" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      ActsAsTenant.with_tenant(@tenant) do
        assert policy.cohort?
        assert policy.attainment?
        refute policy.cohort_full_access?
        refute policy.update?
      end
    end

    should "permit the cohort view for a skip-level (report-of-report) participant" do
      ActsAsTenant.with_tenant(@tenant) do
        lead = create(:person, tenant: @tenant, manager: @manager)
        ic = create(:person, tenant: @tenant, manager: lead)
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: ic.id, status: "enrolled")

        assert AssessmentCyclePolicy.new(@context, @cycle).cohort?
      end
    end
  end

  context "as a manager with no reports in the cycle" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :member)
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant)
        @tenant_user.update!(person: @manager)
        create(:person, tenant: @tenant, manager: @manager) # report, but not enrolled
      end
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @manager)
    end

    should "deny the cohort and attainment views" do
      ActsAsTenant.with_tenant(@tenant) do
        policy = AssessmentCyclePolicy.new(@context, @cycle)
        refute policy.cohort?
        refute policy.attainment?
      end
    end
  end

  context "as a tenant admin" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :admin)
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "permit every action" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      assert policy.index?
      assert policy.show?
      assert policy.define?
      assert policy.enroll?
      assert policy.unenroll?
      assert policy.close?
      assert policy.update?
      assert policy.cohort?
      assert policy.cohort_full_access?
      assert policy.attainment?
    end
  end

  context "as a global admin" do
    setup do
      @user = create(:user, global_admin: true)
      @context = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "permit every action" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      assert policy.index?
      assert policy.show?
      assert policy.define?
      assert policy.enroll?
      assert policy.unenroll?
      assert policy.close?
      assert policy.update?
      assert policy.cohort?
      assert policy.cohort_full_access?
      assert policy.attainment?
    end
  end
end
