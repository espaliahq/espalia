# frozen_string_literal: true

# What the producer endpoints (feed, deletions, ack) share: signature
# authentication, the asking consumer's name, and the 400 for a request the
# peer got wrong.
#
# Include in a controller that inherits ActionController::Base. Auth is the
# request signature alone, as for the Slack inbound endpoints, so there is no
# Pundit `authorize`: a session-less request has no user to authorize.
module FeedbackExchangeProducer
  extend ActiveSupport::Concern

  included do
    include FeedbackExchangeSignedRequest

    around_action :authenticate_feedback_exchange_request!
    rescue_from FeedbackExchange::FeedCursor::Invalid, ActionController::BadRequest,
                ActionDispatch::Http::Parameters::ParseError do
      head :bad_request
    end
  end

  private

  # The system asking, from `X-Exchange-Consumer` (protocol §5). The signature
  # does not cover the header, so it must name the tenant's one configured peer;
  # a request that omits it is that peer.
  #
  # @return [String]
  # @raise [ActionController::BadRequest] when the header names another system
  def exchange_consumer
    configured = exchange_config.peer_name.to_s.strip.downcase
    named = request.headers["X-Exchange-Consumer"].to_s.strip.downcase
    return configured if named.blank?
    raise ActionController::BadRequest, "X-Exchange-Consumer does not match the tenant's peer" unless named == configured

    named
  end

  # @return [FeedbackExchangeConfig]
  def exchange_config
    ActsAsTenant.current_tenant.feedback_exchange_config
  end
end
