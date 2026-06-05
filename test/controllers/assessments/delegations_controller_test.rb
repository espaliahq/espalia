# frozen_string_literal: true

require "test_helper"

class Assessments::DelegationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user, password: "password123")
    @delegate_user = create(:user, password: "password123")
    @stranger_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @delegate = create(:person, tenant: @tenant, email: @delegate_user.email, name: "Delegate")
      create(:tenant_user, tenant: @tenant, user: @delegate_user, person: @delegate)
      @stranger = create(:person, tenant: @tenant, email: @stranger_user.email, name: "Stranger")
      create(:tenant_user, tenant: @tenant, user: @stranger_user, person: @stranger)

      @report = create(:person, tenant: @tenant, name: "Report", manager: @manager)

      @framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: @framework_id, name: "Eng Growth")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")

      PersonDevelopment::CommandHandler.new
        .assign_to_framework(@report.id, @framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  context "POST /assessments/:assessment_id/delegations" do
    should "let the manager grant a delegation" do
      sign_in @manager_user
      post assessment_delegations_path(@assignment),
        params: { delegation: { delegate_person_id: @delegate.id, reason: "seconded" } }

      assert_response :success
      ActsAsTenant.with_tenant(@tenant) do
        assert ManagerAssessmentDelegation.active_delegate?(
          person_id: @report.id, framework_id: @framework_id, delegate_person_id: @delegate.id
        )
      end
    end

    should "forbid an unrelated member from granting" do
      sign_in @stranger_user
      post assessment_delegations_path(@assignment),
        params: { delegation: { delegate_person_id: @delegate.id } }

      assert_response :forbidden
      ActsAsTenant.with_tenant(@tenant) do
        assert_not ManagerAssessmentDelegation.active_delegate?(
          person_id: @report.id, framework_id: @framework_id, delegate_person_id: @delegate.id
        )
      end
    end
  end

  context "DELETE /assessments/:assessment_id/delegations/:id" do
    setup do
      sign_in @manager_user
      post assessment_delegations_path(@assignment),
        params: { delegation: { delegate_person_id: @delegate.id } }
      @delegation = ActsAsTenant.with_tenant(@tenant) do
        ManagerAssessmentDelegation.find_by(delegate_person_id: @delegate.id)
      end
    end

    should "let the manager revoke a delegation" do
      delete assessment_delegation_path(@assignment, @delegation)

      assert_response :success
      ActsAsTenant.with_tenant(@tenant) do
        assert_not ManagerAssessmentDelegation.active_delegate?(
          person_id: @report.id, framework_id: @framework_id, delegate_person_id: @delegate.id
        )
      end
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
