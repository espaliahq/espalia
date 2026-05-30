# frozen_string_literal: true

require "test_helper"

class Assessments::AlignmentRatingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user, password: "password123")
    @report_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @report = create(:person, tenant: @tenant, email: @report_user.email, name: "Report",
        manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @report_user, person: @report)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises information")

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@report.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1 2026", "regular", 1, defined_by: @manager.id)
      cycle_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      # Seed a rating so participant status is `started` — required by
      # AssessmentPolicy#start_alignment?.
      handler.rate_self(@report.id, framework_id, @cap.stable_id,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id)

      # Start alignment so the controller endpoint accepts submissions.
      handler.start_alignment(@report.id, framework_id, @cycle_id, started_by_id: @manager.id)

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  context "POST /assessments/:assessment_id/alignment_ratings" do
    should "create a new alignment rating and return turbo stream" do
      sign_in @manager_user
      post assessment_alignment_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "consistent"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_includes response.media_type, "turbo-stream"

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @report.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2
        )
        assert_equal "consistent", rating.aligned_frequency
      end
    end

    should "clear an existing alignment when the same frequency is posted back" do
      # First call: set alignment.
      sign_in @manager_user
      post assessment_alignment_ratings_path(@report_assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "consistent" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "consistent", AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, capability_stable_id: @cap.stable_id, level_ordinal: 2
        ).aligned_frequency
      end

      # Second call with same frequency: untoggle → clear.
      post assessment_alignment_ratings_path(@report_assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "consistent" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, capability_stable_id: @cap.stable_id, level_ordinal: 2
        )
        assert_nil rating.aligned_frequency, "expected aligned_frequency to clear after untoggle"
      end
    end

    should "replace an existing alignment when a different frequency is posted" do
      sign_in @manager_user
      post assessment_alignment_ratings_path(@report_assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "consistent" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      post assessment_alignment_ratings_path(@report_assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "occasional" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, capability_stable_id: @cap.stable_id, level_ordinal: 2
        )
        assert_equal "occasional", rating.aligned_frequency
      end
    end
  end
end
