# frozen_string_literal: true

# The `/growthos` slash command (POST /slack/commands). Slack sends a
# form-encoded payload and wants an answer within three seconds, so the only
# work here is to resolve who is asking and open the modal; the submission
# comes back through Slack::InteractionsController.
#
# Signature-authenticated, like every inbound Slack endpoint; no session and
# no Pundit (the identity is built from the Slack user — see Slack::Identity —
# and the Operations the modal submission dispatches authorize themselves).
class Slack::CommandsController < ActionController::Base
  include SlackSignedRequest

  before_action :verify_slack_signature!

  USAGE = "Try `/growthos feedback` to give someone feedback."

  # POST /slack/commands
  def create
    subcommand, rest = params[:text].to_s.strip.split(/\s+/, 2)
    return ephemeral(USAGE) unless subcommand.to_s.casecmp?("feedback")

    identity = Slack::Identity.resolve(team_id: params[:team_id], slack_user_id: params[:user_id])
    return ephemeral("This Slack workspace isn't connected to GrowthOS.") unless identity.connected?
    return ephemeral(Slack::Feedback.not_a_member_message(identity)) unless identity.member?

    Slack::Feedback.open_modal(identity, trigger_id: params[:trigger_id], initial_content: rest)
    head :ok
  rescue Slack::Errors::Error => e
    Rails.logger.warn("[slack] command failed: #{e.class}: #{e.message}")
    ephemeral("GrowthOS couldn't open the form just now. Please try again.")
  end

  private

  # Answer the command privately, in place, without any extra Slack call.
  def ephemeral(text)
    render json: { response_type: "ephemeral", text: text }
  end
end
