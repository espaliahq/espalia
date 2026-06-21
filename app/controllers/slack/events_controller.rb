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
# Auth: real event payloads are authenticated by the Slack request SIGNATURE
# (HMAC over the raw body with the app signing secret), not a session — so, like
# Mcp::ServerController, this does NOT inherit ApplicationController (which would
# force Devise) and CSRF is skipped. The `url_verification` handshake is the one
# exception (see #create) and is answered without a signature.
#
# No Pundit `authorize`: a session-less webhook has no user/tenant identity to
# authorize against; the signature is the trust boundary. Same model as
# Mcp::ServerController; Pundit isn't even mixed in (ActionController::Base).
class Slack::EventsController < ActionController::Base
  skip_forgery_protection

  # POST /slack/events
  def create
    # The url_verification handshake is Slack's proof-of-URL-ownership check: it
    # POSTs a random `challenge` and expects it echoed back. It carries no
    # sensitive data and is NOT what the signing secret protects (that's payload
    # authenticity). Answer it WITHOUT a signature — gating the handshake on the
    # signing secret (or on Slack signing the handshake at all, which isn't
    # guaranteed) is the usual cause of "URL isn't verified" at setup time.
    return render(plain: params[:challenge].to_s) if params[:type] == "url_verification"

    # Everything else is a real event payload — verify it's genuinely from Slack.
    return head(:unauthorized) unless slack_signature_valid?

    # TODO: dispatch params[:event] (e.g. message.im) to the evidence-reply
    # handler once that feature is built. Ack for now so Slack doesn't retry.
    head :ok
  end

  private

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
