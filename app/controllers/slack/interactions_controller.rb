# frozen_string_literal: true

# Slack interactive payloads (POST /slack/interactions): the recipient
# typeahead of the feedback modal, the modal's submission, and the "Give
# feedback on this message" message shortcut. One endpoint, as Slack
# requires; the payload's `type` picks the handler.
#
# Signature-authenticated; see Slack::CommandsController for the trust model.
class Slack::InteractionsController < ActionController::Base
  include SlackSignedRequest

  before_action :verify_slack_signature!

  # POST /slack/interactions
  def create
    case payload["type"]
    when "block_suggestion" then suggest
    when "view_submission"  then submit
    when "message_action"   then shortcut
    else head :ok
    end
  rescue Slack::Errors::Error => e
    Rails.logger.warn("[slack] interaction failed: #{e.class}: #{e.message}")
    head :ok
  end

  private

  def payload
    @payload ||= JSON.parse(params[:payload].to_s)
  rescue JSON::ParserError
    {}
  end

  def identity
    @identity ||= Slack::Identity.resolve(team_id: payload.dig("team", "id") || payload["team_id"],
                                          slack_user_id: payload.dig("user", "id"))
  end

  # The recipient external_select asks for options as the giver types.
  def suggest
    return render(json: { options: [] }) unless identity.can_give? && payload["action_id"] == Slack::FeedbackModal::RECIPIENT_ACTION

    recipients = ActsAsTenant.with_tenant(identity.tenant) do
      Assessments::FeedbackRecipients.new(giver: identity.person)
        .call(payload["value"], limit: Assessments::FeedbackRecipients::MAX_LIMIT)
    end
    render json: Slack::FeedbackModal.recipient_options(recipients)
  end

  # The modal was submitted: record the feedback as the giver, or hand the
  # submission to a draft when the giver has no account yet.
  def submit
    return head :ok unless payload.dig("view", "callback_id") == Slack::FeedbackModal::CALLBACK_ID
    return head :ok unless identity.connected?

    result = Slack::Feedback.submit(identity, Slack::FeedbackModal.read(payload["view"]))
    if result.errors.any?
      render json: { response_action: "errors", errors: result.errors }
    else
      render json: { response_action: "clear" }
    end
  end

  # "Feedback on this message": open the modal with the message's text
  # and permalink already in it.
  def shortcut
    return head :ok unless payload["callback_id"] == Slack::Feedback::MESSAGE_SHORTCUT
    return head :ok unless identity.connected?

    unless identity.can_give?
      Slack::Feedback.dm(identity.tenant, payload.dig("user", "id"), Slack::Feedback.not_a_member_message(identity))
      return head :ok
    end

    message = payload["message"] || {}
    Slack::Feedback.open_modal(identity, trigger_id: payload["trigger_id"],
      initial_content: message["text"],
      external_url: Slack::Feedback.permalink(identity.tenant, channel: payload.dig("channel", "id"), message_ts: message["ts"]))
    head :ok
  end
end
