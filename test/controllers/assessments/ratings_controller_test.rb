# frozen_string_literal: true

require "test_helper"

class Assessments::RatingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

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
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1 2026", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  context "POST /assessments/:assessment_id/ratings" do
    should "create a new self-rating and return turbo stream" do
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "consistent",
          comment: "I do this regularly"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_includes response.media_type, "turbo-stream"

      # Verify the rating was persisted
      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id,
          person_id: @person.id,
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2
        )
        assert_not_nil rating
        assert_equal "consistent", rating.self_rated_frequency
      end
    end

    should "stamp data-focused on the rated chip in the turbo stream response" do
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "some"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      cell_id = "cell-#{@cap.stable_id}-2"
      assert_includes response.body, "id=\"#{cell_id}\"",
        "Expected to find the rated chip in the response."
    end

    should "revise an existing self-rating" do
      # Create initial rating
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "some"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success

      # Revise
      post assessment_ratings_path(@assignment), params: {
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
          person_id: @person.id,
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2
        )
        assert_equal "consistent", rating.self_rated_frequency
      end
    end

    should "include scoring panel in turbo stream response" do
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: "occasional"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_includes response.body, "scoring-panel"
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
