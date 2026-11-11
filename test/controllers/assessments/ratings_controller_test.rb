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

  # Every percentage the drawer prints, in order.
  def percents_in(html) = html.to_s.scan(/([+\u2212]?\d+)%/).flatten

  context "POST /assessments/:assessment_id/ratings" do
    # The page's lens, the write's lens and the projection's coverage check
    # all read the same role, so the request builds its scope once (#489).
    should "build the role's scope once for the whole request" do
      sign_in @user
      assert_queries_match(/FROM "framework_capability_role_bindings"/, count: 1) do
        post assessment_ratings_path(@assignment), params: {
          rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "some" }
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_response :success
    end

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

    # The drawer is mounted on the page root so an open dialog survives a
    # frame reload — which also means no frame reload replaces it. Without
    # its own stream it keeps explaining the score the page loaded with.
    should "re-render the score explainer so its arithmetic follows the rating" do
      sign_in @user

      # Two DIFFERENT ratings: asserting the drawer merely renders would pass
      # on a stale copy, since the panel's wording never changes. Only the
      # numbers do, so the test has to watch a number move.
      explainer = lambda do |frequency|
        post assessment_ratings_path(@assignment), params: {
          rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: frequency }
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
        assert_response :success
        response.body[%r{<turbo-stream[^>]*target="score-explainer-modal".*?</turbo-stream>}m]
      end

      some = explainer.call("some")
      assert_not_nil some, "Expected the rating response to replace the explainer drawer."
      assert_includes some, "How it adds up"

      consistent = explainer.call("consistent")
      assert_not_equal percents_in(some), percents_in(consistent),
        "the drawer must explain the score as it is now, not as the page loaded it"
    end

    should "re-render the capability map so its lanes follow the rating" do
      sign_in @user

      lane = lambda do |frequency|
        post assessment_ratings_path(@assignment), params: {
          rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: frequency }
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
        assert_response :success
        stream = response.body[%r{<turbo-stream action="update" target="capability-map-content".*?</turbo-stream>}m]
        assert_not_nil stream, "Expected the rating response to update the capability map's contents, leaving an open map open."
        assert_no_match %r{target="capability-map-modal"}, response.body
        Nokogiri::HTML5.fragment(stream).at_css("[data-capability-lane='1']").text
      end

      assert_includes lane.call("some"), "33% of E2"
      assert_includes lane.call("consistent"), "E2 met"
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

    should "confirm a carried-forward rating on same-frequency click instead of clearing it" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @assignment.framework_id, @cap.stable_id,
          level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id,
          comment: "Seeded from prior cycle", source: "seeded",
          seeded_from_cycle_id: SecureRandom.uuid_v7
        )
      end

      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "occasional" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2)
        assert_equal "occasional", rating.self_rated_frequency, "confirming must keep the value, not clear it"
        assert_equal "human", rating.self_rating_source, "confirming must flip provenance to human"
      end
    end

    should "still untoggle-to-clear a rating the person made themselves" do
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "occasional" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      post assessment_ratings_path(@assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "occasional" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2)
        assert_nil rating.self_rated_frequency
      end
    end

    should "treat a duplicate explicit clear as a no-op, never a re-rate" do
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "occasional" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      # Two explicit clears in a row (double click / second tab): the first
      # clears; the second must no-op instead of falling through to
      # rate_self with the frequency riding on the Clear form.
      2.times do
        post assessment_ratings_path(@assignment), params: {
          rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2,
                    frequency: "occasional", clear: "1" }
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
        assert_response :success
      end

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2)
        assert_nil rating.self_rated_frequency
      end
    end

    should "not 500 when frequency is absent and no rating row exists" do
      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2 }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      # nil frequency == nil existing rating: must classify as a client-level
      # rating error (422 turbo error partial), not a NoMethodError 500.
      assert_response :unprocessable_content
    end

    should "keep evidence and comment glyphs on the rated chip after rating" do
      # Regression: the rating re-render rebuilt the chip without passing
      # viewer_person_id / viewer_sees_all_evidence to the builder, so the
      # rebuilt cell_data had zero evidence/comment counts and the chip lost
      # its corner glyphs the moment you rated it.
      ActsAsTenant.with_tenant(@tenant) do
        handler = PersonDevelopment::CommandHandler.new
        handler.record_evidence(
          @person.id, @framework.framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          source: "self", evidence_type: "project_outcome",
          title: "Q1 launch", content: "Shipped Q1.", author_id: @person.id, valence: "demonstrated"
        )
        handler.post_comment(
          @person.id, @framework.framework_id, SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          author_id: @person.id, body: "Worth a look."
        )
      end

      sign_in @user
      post assessment_ratings_path(@assignment), params: {
        rating: { capability_stable_id: @cap.stable_id, level_ordinal: 2, frequency: "consistent" }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_includes response.body, 'data-glyph="evidence"',
        "Rated chip dropped its evidence glyph in the turbo-stream re-render."
      assert_includes response.body, 'data-glyph="comment"',
        "Rated chip dropped its comment glyph in the turbo-stream re-render."
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
