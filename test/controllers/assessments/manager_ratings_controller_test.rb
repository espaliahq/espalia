# frozen_string_literal: true

require "test_helper"

class Assessments::ManagerRatingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user, password: "password123")
    @report_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @report = create(:person, tenant: @tenant, email: @report_user.email, name: "Report", manager: @manager)
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

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  context "POST /assessments/:assessment_id/manager_ratings" do
    should "create a new manager rating and return turbo stream" do
      sign_in @manager_user
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "occasional",
          comment: "Needs more examples"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_includes response.media_type, "turbo-stream"

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id,
          person_id: @report.id,
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2
        )
        assert_not_nil rating
        assert_equal "occasional", rating.manager_rated_frequency
        assert_equal @manager.id, rating.manager_rated_by_id,
          "expected the acting manager's id to be captured as the rater"
      end
    end

    should "revise an existing manager rating" do
      sign_in @manager_user
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "some"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success

      # Revise
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "consistent"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id,
          person_id: @report.id,
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2
        )
        assert_equal "consistent", rating.manager_rated_frequency
      end
    end

    should "re-render the capability map for the report, read through the manager's ratings" do
      sign_in @manager_user
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "consistent" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      stream = response.body[%r{<turbo-stream action="update" target="capability-map-content".*?</turbo-stream>}m]
      assert_not_nil stream, "Expected the manager rating response to update the capability map's contents, leaving an open map open."
      assert_no_match %r{target="capability-map-modal"}, response.body
      map = Nokogiri::HTML5.fragment(stream)
      assert_includes map.text, "Report at E2"
      assert_includes map.at_css("[data-capability-lane='1']").text, "E2 met"
    end

    should "include scoring panel in turbo stream response" do
      sign_in @manager_user
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "occasional"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_includes response.body, "scoring-panel"
    end

    should "deny access for the report themselves" do
      sign_in @report_user
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "consistent"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      # Report is not manager — Pundit denies manager rating
      assert_response :forbidden
    end

    should "deny access for unrelated users" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other_person = create(:person, tenant: @tenant, email: other_user.email, name: "Other")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other_person)
      end

      sign_in other_user
      post assessment_manager_ratings_path(@report_assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "consistent"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :forbidden
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
