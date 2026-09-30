# frozen_string_literal: true

require "test_helper"

# The alignment milestone endpoints against a lens role (ADR-22): `as_role` /
# `as_level` name the role, the manager lands back on the page read through
# it, and nobody else gets through.
class Assessments::RoleAlignmentMilestonesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @manager_user = create(:user, password: "password123")
    @report_user = create(:user, password: "password123")
    @delegate_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @report = create(:person, tenant: @tenant, email: @report_user.email, manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @report_user, person: @report)
      delegate = create(:person, tenant: @tenant, email: @delegate_user.email)
      create(:tenant_user, tenant: @tenant, user: @delegate_user, person: delegate)
      @assignment, @cycle_id = enrol_in_role_lens_framework(@report, @fx, tenant: @tenant)
      create(:manager_assessment_delegation, tenant: @tenant, person_id: @report.id,
             framework_id: @fx.framework_id, delegate_person_id: delegate.id)
    end
    @pm_lens = { as_role: @fx.pm.role_id, as_level: 2 }
  end

  def pm_row
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentCycleRoleAlignment.find_by(cycle_id: @cycle_id, person_id: @report.id, role_id: @fx.pm.role_id)
    end
  end

  def align_pm_cells
    ActsAsTenant.with_tenant(@tenant) do
      [ @fx.pm_only, @fx.shared ].each do |capability|
        PersonDevelopment::CommandHandler.new.align_assessment(
          @report.id, @fx.framework_id, capability.stable_id, level_ordinal: 2, aligned_frequency: "some",
          cycle_id: @cycle_id, aligned_by_id: @manager.id, role_id: @fx.pm.role_id
        )
      end
    end
  end

  context "POST alignment_start against PM2" do
    should "start it and land the manager on the PM2 lens" do
      sign_in @manager_user
      post assessment_alignment_start_path(@assignment), params: @pm_lens

      assert_redirected_to assessment_path(@assignment, @pm_lens)
      assert_match(/Alignment against PM2 started/, flash[:notice])
      assert_equal "aligning", pm_row.status
    end

    should "deny the assessee" do
      sign_in @report_user
      post assessment_alignment_start_path(@assignment), params: @pm_lens

      assert_response :forbidden
      assert_nil pm_row
    end

    should "deny a rating delegate" do
      sign_in @delegate_user
      post assessment_alignment_start_path(@assignment), params: @pm_lens

      assert_response :forbidden
      assert_nil pm_row
    end
  end

  context "once PM2 alignment has started" do
    setup do
      sign_in @manager_user
      post assessment_alignment_start_path(@assignment), params: @pm_lens
    end

    should "refuse completion until every PM2 cell is agreed" do
      post assessment_alignment_completion_path(@assignment), params: @pm_lens

      assert_redirected_to assessment_path(@assignment, @pm_lens)
      assert_match(/2 current-level capabilities still need an agreed rating/, flash[:alert])
      assert_equal "aligning", pm_row.status
    end

    should "complete, then re-open, PM2 alone" do
      align_pm_cells
      post assessment_alignment_completion_path(@assignment), params: @pm_lens
      assert_match(/Alignment against PM2 complete/, flash[:notice])
      assert_equal "aligned", pm_row.status

      post assessment_alignment_reopening_path(@assignment), params: @pm_lens
      assert_redirected_to assessment_path(@assignment, @pm_lens)
      assert_equal "aligning", pm_row.status
    end

    should "deny the assessee completing or re-opening it" do
      align_pm_cells
      delete destroy_user_session_path
      sign_in @report_user
      post assessment_alignment_completion_path(@assignment), params: @pm_lens
      assert_response :forbidden

      post assessment_alignment_reopening_path(@assignment), params: @pm_lens
      assert_response :forbidden
    end

    should "refuse a second start" do
      post assessment_alignment_start_path(@assignment), params: @pm_lens
      assert_response :forbidden
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
