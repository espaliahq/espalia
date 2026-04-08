# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::EnrollmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email, name: "Admin User")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin_person, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state,
        framework_id: @framework_id,
        name: "Engineering Growth",
        current_published_version: 1
      )
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      @assigned_person = create(:person, tenant: @tenant, name: "Assigned", email: "assigned@example.com")
      @unassigned_person = create(:person, tenant: @tenant, name: "Unassigned", email: "unassigned@example.com")

      PersonDevelopment::CommandHandler.new.assign_to_framework(
        @assigned_person.id, @framework_id, @role.role_id, @level.level_id
      )

      @cycle_id = SecureRandom.uuid_v7
      AssessmentCycles::CommandHandler.new.define_cycle(
        @cycle_id, @framework_id, "Q1 2026", "regular", 1
      )
      @cycle = AssessmentCycle.find_by!(cycle_id: @cycle_id)
    end
  end

  context "as tenant admin" do
    context "POST enrollments" do
      should "enroll a person assigned to the framework" do
        sign_in @admin_user
        assert_difference -> { AssessmentCycleParticipant.count }, 1 do
          post assessment_cycle_enrollments_path(@cycle), params: {
            enrollment: { person_id: @assigned_person.id }
          }
        end
        assert_redirected_to assessment_cycle_path(@cycle)

        ActsAsTenant.with_tenant(@tenant) do
          participant = AssessmentCycleParticipant.find_by(
            cycle_id: @cycle_id, person_id: @assigned_person.id
          )
          assert_not_nil participant
          assert_equal "enrolled", participant.status
        end
      end

      should "reject enrollment for a person not assigned to the framework" do
        sign_in @admin_user
        assert_no_difference -> { AssessmentCycleParticipant.count } do
          post assessment_cycle_enrollments_path(@cycle), params: {
            enrollment: { person_id: @unassigned_person.id }
          }
        end
        assert_redirected_to assessment_cycle_path(@cycle)
        follow_redirect!
        assert_match(/not yet assigned|Person not yet assigned/i, flash[:alert].to_s)
      end
    end

    context "DELETE enrollments/:id" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          AssessmentCycles::CommandHandler.new.enroll(@cycle_id, @assigned_person.id)
          @participant = AssessmentCycleParticipant.find_by!(
            cycle_id: @cycle_id, person_id: @assigned_person.id
          )
        end
      end

      should "withdraw the participant" do
        sign_in @admin_user
        delete assessment_cycle_enrollment_path(@cycle, @participant), params: { reason: "left_company" }

        assert_redirected_to assessment_cycle_path(@cycle)
        ActsAsTenant.with_tenant(@tenant) do
          assert_equal "withdrawn", @participant.reload.status
          assert_equal "left_company", @participant.withdrawal_reason
        end
      end
    end
  end

  context "as tenant member" do
    should "deny POST enrollments" do
      sign_in @member_user
      post assessment_cycle_enrollments_path(@cycle), params: {
        enrollment: { person_id: @assigned_person.id }
      }
      assert_redirected_to root_path
    end

    should "deny DELETE enrollments" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.enroll(@cycle_id, @assigned_person.id)
        @participant = AssessmentCycleParticipant.find_by!(
          cycle_id: @cycle_id, person_id: @assigned_person.id
        )
      end

      sign_in @member_user
      delete assessment_cycle_enrollment_path(@cycle, @participant)
      assert_redirected_to root_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
