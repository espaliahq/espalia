# frozen_string_literal: true

# Authenticates an inbound Slack request by its signature — the trust boundary
# for every session-less Slack endpoint (events, slash commands, interactive
# payloads). Slack signs the RAW body, so the check reads `request.raw_post`,
# never re-serialised params.
#
# Include in a controller that inherits ActionController::Base directly (no
# Devise, no CSRF) and call `verify_slack_signature!` as a before_action.
module SlackSignedRequest
  extend ActiveSupport::Concern

  included do
    skip_forgery_protection
  end

  private

  def verify_slack_signature!
    head :unauthorized unless slack_signature_valid?
  end

  # @return [Boolean] whether the request is a genuine, fresh, signed Slack call.
  #   A missing signing secret is a misconfiguration — fail closed.
  def slack_signature_valid?
    Slack::RequestVerifier.valid?(
      signature: request.headers["X-Slack-Signature"],
      timestamp: request.headers["X-Slack-Request-Timestamp"],
      body: request.raw_post,
      secret: Slack.oauth_config[:signing_secret]
    )
  end
end
