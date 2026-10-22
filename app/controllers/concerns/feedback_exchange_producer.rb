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

  # The system asking. {FeedbackExchangeSignedRequest} has already refused a
  # request whose `X-Exchange-Consumer` is not the tenant's peer.
  #
  # @return [String]
  def exchange_consumer
    exchange_config.peer_name.to_s.strip.downcase
  end

  # @return [FeedbackExchangeConfig]
  def exchange_config
    ActsAsTenant.current_tenant.feedback_exchange_config
  end
end
