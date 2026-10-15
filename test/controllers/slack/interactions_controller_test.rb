# frozen_string_literal: true

require "test_helper"
require_relative "../../support/slack_fixture"

# The feedback modal's round trip: the recipient typeahead, a submission that
# records evidence as the giver (placed or unplaced), the errors a bad
# submission gets back, the draft-and-link path for a giver with no account,
# and the message shortcut that opens the modal prefilled.
class Slack::InteractionsControllerTest < ActionDispatch::IntegrationTest
  include SlackFixture
  include ActiveJob::TestHelper

  setup { build_slack_fixture }

  def post_interaction(payload, signed: true)
    body = { payload: payload.to_json }.to_query
    headers = signed ? signed_slack_headers(body) : {}
    Slack.stub(:oauth_config, { signing_secret: SECRET }) do
      post slack_interactions_path, params: body, headers: headers.merge("CONTENT_TYPE" => "application/x-www-form-urlencoded")
    end
  end

  def submission(user_id: "U_JORDAN", assignment_id: nil, content: "Ran the incident call calmly.", capability: nil, valence: nil, external_url: nil)
    b = Slack::FeedbackModal::BLOCKS
    values = {
      b[:recipient] => { Slack::FeedbackModal::RECIPIENT_ACTION => { "selected_option" => assignment_id && { "value" => assignment_id } } },
      b[:content] => { b[:content] => { "value" => content } },
      b[:type] => { b[:type] => { "selected_option" => { "value" => "peer_feedback" } } },
      b[:capability] => { b[:capability] => { "selected_option" => capability && { "value" => capability } } },
      b[:valence] => { b[:valence] => { "selected_option" => valence && { "value" => valence } } }
    }
    { type: "view_submission", team: { id: TEAM_ID }, user: { id: user_id },
      view: { callback_id: Slack::FeedbackModal::CALLBACK_ID, private_metadata: { external_url: external_url }.compact.to_json,
              state: { values: values } } }
  end

  context "block_suggestion" do
    should "offer the recipient directory's matches as options" do
      with_fake_slack do
        post_interaction({ type: "block_suggestion", team: { id: TEAM_ID }, user: { id: "U_JORDAN" },
                           action_id: Slack::FeedbackModal::RECIPIENT_ACTION, value: "ale" })
        assert_response :success
        options = response.parsed_body["options"]
        assert_equal [ @assignment.id ], options.map { |o| o["value"] }
        assert_equal "Alex Chen", options.first.dig("text", "text")
        assert_equal "SWE · E2", options.first.dig("description", "text")
      end
    end
  end

  context "view_submission by a member" do
    should "record unplaced feedback as the giver, attributed to Slack, and DM a confirmation" do
      with_fake_slack do |fake|
        perform_enqueued_jobs { post_interaction(submission(assignment_id: @assignment.id)) }
        assert_response :success
        assert_equal "clear", response.parsed_body["response_action"]

        ActsAsTenant.with_tenant(@tenant) do
          item = EvidenceItem.unplaced.for_person(@recipient.id).sole
          assert_equal @giver.id, item.author_id
          assert_equal "peer", item.source
          event = Rails.configuration.event_store.read.of_type(PersonDevelopment::Events::EvidenceRecorded).to_a.last
          assert_equal "slack", event.metadata[:acting_via]
          assert_equal @giver.id, event.metadata[:actor_id]
        end
        dm = fake.calls.find { |c| c.first == :post_dm }
        assert_equal "U_JORDAN", dm[1]
        assert_match(/not yet placed/, dm[2])
        assert_equal 1, @recipient_user.notifications.reload.size
      end
    end

    should "place feedback at the recipient's level when a capability and valence are given, keeping the permalink" do
      with_fake_slack do
        post_interaction(submission(assignment_id: @assignment.id, capability: @cap.stable_id, valence: "demonstrated",
                                    external_url: "https://slack.example/archives/C1/p1"))
        assert_equal "clear", response.parsed_body["response_action"]
        ActsAsTenant.with_tenant(@tenant) do
          item = EvidenceItem.active.where(author_id: @giver.id).sole
          assert_equal @cap.stable_id, item.capability_stable_id
          assert_equal 2, item.level_ordinal
          assert_equal "slack", item.external_reference.system
          assert_equal "https://slack.example/archives/C1/p1", item.external_reference.url
        end
      end
    end

    should "return form errors for a missing recipient, empty text, or a capability without a valence" do
      with_fake_slack do
        post_interaction(submission(assignment_id: nil, content: ""))
        errors = response.parsed_body["errors"]
        assert_equal "errors", response.parsed_body["response_action"]
        assert errors.key?(Slack::FeedbackModal::BLOCKS[:recipient])
        assert errors.key?(Slack::FeedbackModal::BLOCKS[:content])

        post_interaction(submission(assignment_id: @assignment.id, capability: @cap.stable_id))
        assert response.parsed_body["errors"].key?(Slack::FeedbackModal::BLOCKS[:valence])
        ActsAsTenant.with_tenant(@tenant) { assert_empty EvidenceItem.where(author_id: @giver.id) }
      end
    end

    should "turn a capability the role has no expectation for into a form error, not a failed write" do
      with_fake_slack do
        other = ActsAsTenant.with_tenant(@tenant) do
          cat = FrameworkState::CapabilityCategory.find_by(framework_id: @framework_id)
          create(:framework_capability, category_id: cat.category_id, name: "Unbound")
        end
        post_interaction(submission(assignment_id: @assignment.id, capability: other.stable_id, valence: "demonstrated"))
        assert_equal "errors", response.parsed_body["response_action"]
      end
    end
  end

  context "view_submission by an HRIS-known person who never signed in" do
    should "keep a draft bound to their email and DM them the sign-in link" do
      with_fake_slack do |fake|
        post_interaction(submission(user_id: "U_NIA", assignment_id: @assignment.id, content: "Great call."))
        assert_equal "clear", response.parsed_body["response_action"]

        draft = ActsAsTenant.with_tenant(@tenant) { FeedbackDraft.sole }
        assert_equal "newcomer@example.com", draft.author_email
        assert_equal @assignment.id, draft.assignment_id
        assert_equal "Great call.", draft.content
        assert draft.expires_at > 7.days.from_now
        dm = fake.calls.find { |c| c.first == :post_dm }
        assert_equal "U_NIA", dm[1]
        assert_includes dm[2], draft.path
        ActsAsTenant.with_tenant(@tenant) { assert_empty EvidenceItem.all }
      end
    end
  end

  context "message shortcut" do
    should "open the modal with the message text and its permalink" do
      with_fake_slack do |fake|
        post_interaction({ type: "message_action", callback_id: Slack::Feedback::MESSAGE_SHORTCUT, trigger_id: "trig.9",
                           team: { id: TEAM_ID }, user: { id: "U_JORDAN" }, channel: { id: "C1" },
                           message: { text: "Thanks for running point on the outage", ts: "1700000000.000100" } })
        assert_response :success
        call = fake.calls.find { |c| c.first == :open_view }
        view = call[2]
        content = view[:blocks].find { |b| b[:block_id] == Slack::FeedbackModal::BLOCKS[:content] }
        assert_equal "Thanks for running point on the outage", content[:element][:initial_value]
        assert_equal "https://slack.example/archives/C1/p1700000000000100", JSON.parse(view[:private_metadata])["external_url"]
      end
    end

    should "DM a stranger instead of opening anything" do
      with_fake_slack do |fake|
        post_interaction({ type: "message_action", callback_id: Slack::Feedback::MESSAGE_SHORTCUT, trigger_id: "t",
                           team: { id: TEAM_ID }, user: { id: "U_GHOST" }, channel: { id: "C1" }, message: { text: "x", ts: "1.2" } })
        assert_response :success
        assert_empty fake.calls.select { |c| c.first == :open_view }
        assert fake.calls.any? { |c| c.first == :post_dm && c[2].include?("No GrowthOS account") }
      end
    end
  end

  should "reject an unsigned payload" do
    post_interaction(submission(assignment_id: @assignment.id), signed: false)
    assert_response :unauthorized
  end
end
