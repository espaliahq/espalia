# frozen_string_literal: true

# Signed liveness check (GET /api/feedback_exchange/health).
#
# Lets a pair be verified end to end before any data flows: a 200 proves the
# caller signed with the tenant's inbound secret. Auth is the request signature
# alone, as for the Slack inbound endpoints, so there is no Pundit `authorize`:
# a session-less request has no user to authorize.
class FeedbackExchange::HealthController < ActionController::Base
  include FeedbackExchangeSignedRequest

  around_action :authenticate_feedback_exchange_request!

  # GET /api/feedback_exchange/health
  def show
    render json: { ok: true, peer: ActsAsTenant.current_tenant.feedback_exchange_config.peer_name }
  end
end
