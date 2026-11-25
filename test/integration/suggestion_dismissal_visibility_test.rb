# frozen_string_literal: true

require "test_helper"
require_relative "../support/placement_suggestion_fixture"

# Who reads a dismissed suggestion and its reason, in the activity feed and the
# link's thread ([#539](https://github.com/espaliahq/espalia/issues/539) c4).
class SuggestionDismissalVisibilityTest < ActionDispatch::IntegrationTest
  include PlacementSuggestionFixture

  REASON = "Wrong behaviour for this one"

  setup do
    build_placement_fixture
    @admin_user = create(:user, password: "password123", email: "riley@example.com")
    @casey_user = create(:user, password: "password123", email: "casey@example.com")
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:person, tenant: @tenant, email: @admin_user.email, name: "Riley Admin")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin, role: :admin)
      @casey = create(:person, tenant: @tenant, email: @casey_user.email, name: "Casey Park")
      create(:tenant_user, tenant: @tenant, user: @casey_user, person: @casey, role: :member)
    end

    @item = record_peer_feedback(placed_on: @ownership)
    record_feedback_from(@casey)
    dismiss_on(@collaboration, by: @jordan)
    link_on(@collaboration)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "the activity feed" do
    should "show the dismissal and its reason to the assessee" do
      assert_feed_shows_dismissal(@alex_user)
    end

    should "show it to the manager" do
      assert_feed_shows_dismissal(@morgan_user)
    end

    should "show it to an admin" do
      assert_feed_shows_dismissal(@admin_user)
    end

    # A peer can't open the assessment, so the author meets the rule only in
    # the queries below.
    should "keep the assessment closed to the author who dismissed it" do
      assert_feed_hides_dismissal(@jordan_user)
      assert_redirected_to assessments_path
    end

    should "show another peer author neither the entry nor the reason" do
      assert_feed_hides_dismissal(@casey_user)
    end

    should "show an unrelated peer neither the entry nor the reason" do
      assert_feed_hides_dismissal(@stranger_user)
    end

    should "name a forgotten dismisser as a former member" do
      ActsAsTenant.with_tenant(@tenant) { @jordan.update_columns(name: Person::FORMER_MEMBER, forgotten_at: Time.current) }
      sign_in(@alex_user)
      get assessment_activity_path(@assignment)

      assert_includes response.body, "#{Person::FORMER_MEMBER} dismissed the suggested placement"
      refute_includes response.body, "Jordan Lee"
    end
  end

  context "the link's thread" do
    should "show the dismissal and its reason to the assessee, the manager and an admin" do
      [ @alex_user, @morgan_user, @admin_user ].each do |user|
        sign_in(user)
        get thread_path(@collaboration)

        assert_response :success
        assert_includes response.body, "dismissed a suggestion to place this feedback here — #{REASON}", user.email
      end
    end

    should "leave it out of a thread on another cell" do
      sign_in(@alex_user)
      get thread_path(@ownership)

      assert_response :success
      refute_includes response.body, REASON
    end

    should "show neither the entry nor the reason to any peer" do
      [ @jordan_user, @casey_user, @stranger_user ].each do |user|
        sign_in(user)
        get thread_path(@collaboration)

        refute_includes response.body, REASON, user.email
        refute_includes response.body, "dismissed a suggestion", user.email
      end
    end
  end

  context "the queries, for a viewer who doesn't see the whole assessment" do
    should "give the author who dismissed it their own entry and reason" do
      assert_equal [ REASON ], feed_reasons(@jordan)
      assert_equal [ REASON ], thread_reasons(@jordan)
    end

    should "give another peer author neither" do
      assert_empty feed_reasons(@casey)
      assert_empty thread_reasons(@casey)
    end

    should "give an unrelated peer neither" do
      assert_empty feed_reasons(@stranger)
      assert_empty thread_reasons(@stranger)
    end
  end

  private

  def feed_reasons(viewer)
    ActsAsTenant.with_tenant(@tenant) do
      Assessments::ActivityFeedQuery.new(assignment: @assignment, viewer_person_id: viewer.id, viewer_sees_all: false)
        .call.select { it.kind == Assessments::ActivityFeedQuery::SUGGESTION_DISMISSED_KIND }.map { it.payload[:reason] }
    end
  end

  def thread_reasons(viewer)
    ActsAsTenant.with_tenant(@tenant) do
      Assessments::EvidenceLinkThreadQuery.new(item: @item, capability_stable_id: @collaboration.stable_id, level_ordinal: 3,
                                               viewer_person_id: viewer.id, viewer_sees_all: false)
        .lifecycle_entries.select { it.kind == :suggestion_dismissed }.map(&:reason)
    end
  end

  def sign_in(user)
    delete destroy_user_session_path
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def thread_path(capability)
    assessment_evidence_link_thread_path(@assignment, @item.id, capability_stable_id: capability.stable_id, level_ordinal: 3)
  end

  def assert_feed_shows_dismissal(user)
    sign_in(user)
    get assessment_activity_path(@assignment)

    assert_response :success
    assert_includes response.body, "Jordan Lee dismissed the suggested placement of"
    assert_includes response.body, REASON
  end

  def assert_feed_hides_dismissal(user)
    sign_in(user)
    get assessment_activity_path(@assignment)

    refute_includes response.body, REASON
    refute_includes response.body, "dismissed the suggested placement"
  end

  def record_feedback_from(author)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.record_evidence(@alex.id, @framework_id, SecureRandom.uuid_v7,
        source: "peer", evidence_type: "peer_feedback", content: "Alex paired with me on the rollout.",
        author_id: author.id)
    end
  end

  def dismiss_on(capability, by:)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::Repository.new.with_person_development(@alex.id, @framework_id) do |aggregate|
        aggregate.suggest_placements(@item.id, proposals: [
          { capability_stable_id: capability.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: "0.8",
            rationale: "Kept everyone informed." }
        ], provider: "anthropic", model: "test-model", prompt_version: "v1", generated_at: "2026-11-24T10:00:00Z")
      end
      suggestion_id = EvidencePlacementSuggestion.pending.for_evidence(@item.id).sole.id
      PersonDevelopment::Repository.new.with_person_development(@alex.id, @framework_id) do |aggregate|
        aggregate.dismiss_suggestion(suggestion_id, evidence_id: @item.id, dismissed_by_id: by.id, reason: REASON)
      end
    end
  end

  def link_on(capability)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.add_evidence_link(@alex.id, @framework_id, @item.id,
        capability_stable_id: capability.stable_id, level_ordinal: 3, linked_by_id: @morgan.id, valence: "demonstrated")
    end
  end
end
