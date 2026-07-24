# frozen_string_literal: true

require "test_helper"

class CalibrationSessionPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      # Org: dept_head → em → ic (dept_head manages a manager)
      @dept_head = create(:person, tenant: @tenant, name: "Dept Head")
      @em = create(:person, tenant: @tenant, name: "EM", manager: @dept_head)
      @ic = create(:person, tenant: @tenant, name: "IC", manager: @em)
      @session = create(:calibration_session, tenant: @tenant, facilitator_id: @dept_head.id)
    end
  end

  def context_for(person:, role: :member, user: nil)
    user ||= create(:user)
    tenant_user = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, user: user, tenant: @tenant, role: role, person: person)
    end
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person)
  end

  context "as non-member" do
    should "deny everything" do
      ctx = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)
      policy = CalibrationSessionPolicy.new(ctx, @session)

      assert_not policy.index?
      assert_not policy.define?
      assert_not policy.show?
      assert_not policy.curate?
      assert_not policy.start?
      assert_not policy.close?
    end
  end

  context "as a member without reports" do
    should "deny index and define" do
      ActsAsTenant.with_tenant(@tenant) do
        policy = CalibrationSessionPolicy.new(context_for(person: @ic), CalibrationSession)
        assert_not policy.index?
        assert_not policy.define?
      end
    end
  end

  context "as a manager of ICs only" do
    should "deny define — no one in their subtree manages anyone" do
      ActsAsTenant.with_tenant(@tenant) do
        policy = CalibrationSessionPolicy.new(context_for(person: @em), CalibrationSession)
        assert_not policy.define?
      end
    end

    should "deny show on a session where they are a participant (v1 facilitator-only)" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:calibration_session_member, :participant,
               tenant: @tenant, session: @session, person_id: @em.id)
        policy = CalibrationSessionPolicy.new(context_for(person: @em), @session)
        assert_not policy.show?
        assert_not policy.curate?
        assert_not policy.start?
      end
    end
  end

  context "as a manager of managers" do
    setup do
      ActsAsTenant.with_tenant(@tenant) { @ctx = context_for(person: @dept_head) }
    end

    should "permit index and define" do
      ActsAsTenant.with_tenant(@tenant) do
        policy = CalibrationSessionPolicy.new(@ctx, CalibrationSession)
        assert policy.index?
        assert policy.define?
      end
    end

    should "permit show/curate/start/close on their own session" do
      ActsAsTenant.with_tenant(@tenant) do
        policy = CalibrationSessionPolicy.new(@ctx, @session)
        assert policy.show?
        assert policy.curate?
        assert policy.start?
        assert policy.close?
      end
    end

    should "deny show/curate on someone else's session" do
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:calibration_session, tenant: @tenant)
        policy = CalibrationSessionPolicy.new(@ctx, other)
        assert_not policy.show?
        assert_not policy.curate?
        assert_not policy.start?
        assert_not policy.close?
      end
    end
  end

  context "as tenant admin" do
    should "permit everything, incl. sessions they don't facilitate" do
      ActsAsTenant.with_tenant(@tenant) do
        admin_person = create(:person, tenant: @tenant, name: "HR Admin")
        ctx = context_for(person: admin_person, role: :admin)
        policy = CalibrationSessionPolicy.new(ctx, @session)

        assert policy.index?
        assert policy.define?
        assert policy.show?
        assert policy.curate?
        assert policy.start?
        assert policy.close?
      end
    end

    should "deny define without a linked person (facilitator is required)" do
      ActsAsTenant.with_tenant(@tenant) do
        ctx = context_for(person: nil, role: :admin)
        policy = CalibrationSessionPolicy.new(ctx, CalibrationSession)

        assert_not policy.define?
        assert policy.show?, "session drive stays available to admins without a person"
      end
    end
  end
end
