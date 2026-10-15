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

  # Slack retries a request it did not hear back from inside the window the
  # signature's timestamp allows, and a captured request can be replayed in
  # it; either would reach the write twice. The signature is unique to one
  # body and timestamp, so claiming it once is the replay guard.
  REPLAY_WINDOW = Slack::RequestVerifier::MAX_SKEW_SECONDS.seconds

  private

  def verify_slack_signature!
    return head :unauthorized unless slack_signature_valid?

    head :ok unless claim_slack_request!
  end

  # @return [Boolean] false when this signed request was already accepted
  def claim_slack_request!
    key = "slack:request:#{request.headers["X-Slack-Signature"]}"
    Rails.cache.write(key, true, unless_exist: true, expires_in: REPLAY_WINDOW)
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
