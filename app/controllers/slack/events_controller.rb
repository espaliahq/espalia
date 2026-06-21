# frozen_string_literal: true

# Inbound Slack Events API endpoint (POST /slack/events).
#
# Today this exists for ONE concrete reason: to answer Slack's `url_verification`
# challenge so the Events request URL can be saved/verified, which in turn lets
# the manifest declare a `message.im` subscription (Slack challenge-verifies
# Events URLs the moment they're set — see app/integrations/slack/manifest.yml).
#
# It is the entry point for the planned "capture a free-text DM reply to an
# evidence request" feature; that handling isn't built yet, so real
# `event_callback` payloads are acknowledged (200) and dropped. Acking keeps
# Slack from retrying and eventually disabling the subscription.
#
# Auth is the Slack request SIGNATURE (HMAC over the raw body with the app
# signing secret), not a session — so, like Mcp::ServerController, this does NOT
# inherit ApplicationController (which would force Devise) and CSRF is skipped.
class Slack::EventsController < ActionController::Base
  skip_forgery_protection

  # No Pundit `authorize`: this is an unauthenticated-by-session webhook with no
  # user/tenant identity to authorize against. Trust is established by the Slack
  # request signature (verify_slack_signature, fail-closed) — the same model as
  # Mcp::ServerController, which is token-authenticated and likewise calls no
  # Pundit policy. Pundit's machinery isn't even mixed in here (ActionController::Base).
  before_action :verify_slack_signature

  # POST /slack/events
  def create
    case params[:type]
    when "url_verification"
      # Echo the challenge so Slack marks the Events URL verified.
      render plain: params[:challenge].to_s
    when "event_callback"
      # TODO: dispatch params[:event] (e.g. message.im) to the evidence-reply
      # handler once that feature is built. Ack for now so Slack doesn't retry.
      head :ok
    else
      head :ok
    end
  end

  private

  # Reject anything not signed by Slack. A missing signing secret is a
  # misconfiguration — fail closed rather than accept unsigned payloads.
  def verify_slack_signature
    return if Slack::RequestVerifier.valid?(
      signature: request.headers["X-Slack-Signature"],
      timestamp: request.headers["X-Slack-Request-Timestamp"],
      body: request.raw_post,
      secret: Slack.oauth_config[:signing_secret]
    )

    head :unauthorized
  end
end
