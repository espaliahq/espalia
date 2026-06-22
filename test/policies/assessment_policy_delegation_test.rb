# frozen_string_literal: true

require "test_helper"

# Delegation + recorded-authoritative reporting-manager behaviour on
# AssessmentPolicy.
class AssessmentPolicyDelegationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, name: "Report")
      @manager = create(:person, tenant: @tenant, name: "Manager")
      @skip = create(:person, tenant: @tenant, name: "Skip")
      @delegate = create(:person, tenant: @tenant, name: "Delegate")
      @person.update!(manager: @manager)
      @manager.update!(manager: @skip)
      @framework = create(:framework_state, name: "FW")
      @assignment = create(:person_framework_assignment, tenant: @tenant,
        person_id: @person.id, framework_id: @framework.framework_id)
    end
  end

  def ctx_for(person, admin: false)
    user = create(:user)
    tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: user, person: person, role: admin ? :admin : :member)
    end
    AuthorizationContext.new(user: user, tenant_user: tu, person: person)
  end

  def policy(person, **opts)
    AssessmentPolicy.new(ctx_for(person, **opts), @assignment)
  end

  context "active delegate" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
          framework_id: @framework.framework_id, delegate_person_id: @delegate.id,
          granted_by_id: @manager.id)
      end
    end

    should "permit create_manager_rating" do
      assert policy(@delegate).create_manager_rating?
    end

    should "permit show" do
      assert policy(@delegate).show?
    end

    should "deny start_alignment and create_alignment_rating" do
      assert_not policy(@delegate).start_alignment?
      assert_not policy(@delegate).create_alignment_rating?
    end

    should "deny reopen_alignment (manager-only, never a delegate)" do
      assert_not policy(@delegate).reopen_alignment?
    end

    should "deny manager rating once the delegation is expired" do
      ManagerAssessmentDelegation.where(delegate_person_id: @delegate.id)
        .update_all(expires_at: 1.day.ago)
      assert_not policy(@delegate).create_manager_rating?
    end
  end

  context "grant authority (delegate_manager_rating?)" do
    should "permit the direct manager" do
      assert policy(@manager).delegate_manager_rating?
    end

    should "permit a skip-level (ancestor) manager" do
      assert policy(@skip).delegate_manager_rating?
    end

    should "permit a tenant admin" do
      assert policy(@delegate, admin: true).delegate_manager_rating?
    end

    should "deny an unrelated member" do
      unrelated = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
      assert_not policy(unrelated).delegate_manager_rating?
    end
  end

  context "recorded-authoritative manager" do
    should "treat the recorded manager as manager even if live manager_id differs" do
      other = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
      ActsAsTenant.with_tenant(@tenant) do
        create(:recorded_reporting_manager, tenant: @tenant, person_id: @person.id,
          framework_id: @framework.framework_id, manager_id: other.id)
      end

      assert policy(other).create_manager_rating?
      assert_not policy(@manager).create_manager_rating? # live manager no longer authoritative
    end

    should "fall back to live manager_id when nothing is recorded" do
      assert policy(@manager).create_manager_rating?
    end
  end

  context "unassign?" do
    should "permit a tenant admin" do
      assert policy(@delegate, admin: true).unassign?
    end

    should "deny the assessee, their manager, and a skip-level manager" do
      assert_not policy(@person).unassign?
      assert_not policy(@manager).unassign?
      assert_not policy(@skip).unassign?
    end
  end
end
