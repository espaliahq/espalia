# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::EvidenceReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @framework_id = SecureRandom.uuid_v7
      @role = create(:framework_role, name: "Engineer")
      @cycle = create(:assessment_cycle,
        tenant: @tenant, name: "Q1 2026", framework_id: @framework_id)

      @manager_user = create(:user, password: "password123")
      @manager = create(:person,
        tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user,
        tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report", manager: @manager)
      enroll(@report)

      @other_manager = create(:person, tenant: @tenant, name: "Other Manager")
      other = create(:person, tenant: @tenant, name: "Other", manager: @other_manager)
      enroll(other)

      author = create(:person, tenant: @tenant, name: "Author")
      create(:evidence_item, with_link: false,
        tenant: @tenant, author: author, person_id: @report.id,
        framework_id: @framework_id, cycle_id: @cycle.cycle_id,
        content: "Private feedback content")
      requested = create(:evidence_item, with_link: false,
        tenant: @tenant, author: author, person_id: @report.id,
        framework_id: @framework_id, cycle_id: @cycle.cycle_id)
      create(:evidence_request,
        tenant: @tenant, requester: @manager, requestee: author,
        person_id: @report.id, framework_id: @framework_id,
        cycle_id: @cycle.cycle_id, status: "responded",
        evidence_id: requested.id, requested_at: 1.minute.ago)

      @admin_user = create(:user, password: "password123")
      admin = create(:person,
        tenant: @tenant, email: @admin_user.email, name: "Admin")
      create(:tenant_user,
        tenant: @tenant, user: @admin_user, person: admin, role: :admin)

      @outsider_user = create(:user, password: "password123")
      outsider = create(:person,
        tenant: @tenant, email: @outsider_user.email, name: "Outsider")
      create(:tenant_user,
        tenant: @tenant, user: @outsider_user, person: outsider, role: :member)
    end
  end

  context "GET /assessment_cycles/:id/evidence" do
    should "render scoped feedback coverage for a manager without private content" do
      sign_in @manager_user
      get evidence_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "feedback &amp; evidence"
      assert_includes response.body, "Feedback provided"
      assert_includes response.body, "Unsolicited"
      assert_includes response.body, "Manager"
      assert_not_includes response.body, "Other Manager"
      assert_not_includes response.body, "Private feedback content"
    end

    should "render whole-cycle coverage for an admin" do
      sign_in @admin_user
      get evidence_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "Other Manager"
    end

    should "honour the role grouping" do
      sign_in @admin_user
      get evidence_assessment_cycle_path(@cycle, group: "role")

      assert_response :success
      assert_includes response.body, "Engineer"
      assert_includes response.body, "Feedback and evidence coverage by role"
    end

    should "narrow an admin to their own empty subtree" do
      sign_in @admin_user
      get evidence_assessment_cycle_path(@cycle, scope: "mine")

      assert_response :success
      assert_includes response.body, "No participants"
    end

    should "deny a member with no reports in the cycle" do
      sign_in @outsider_user
      get evidence_assessment_cycle_path(@cycle)

      assert_response :redirect
    end

    should "redirect unauthenticated users to sign in" do
      get evidence_assessment_cycle_path(@cycle)

      assert_redirected_to new_user_session_path
    end
  end

  private

  def enroll(person)
    create(:assessment_cycle_enrollment,
      tenant: @tenant, cycle: @cycle, person_id: person.id,
      role_id: @role.role_id, level_ordinal: 2, enrolled_at: 1.day.ago)
  end

  def sign_in(user)
    post user_session_path,
      params: { user: { email: user.email, password: "password123" } }
  end
end
