# frozen_string_literal: true

# Acknowledgements (POST /api/feedback_exchange/feedback/ack), protocol §5.3:
# the peer says where each imported item now also lives.
class FeedbackExchange::AcksController < ActionController::Base
  include FeedbackExchangeProducer

  # POST /api/feedback_exchange/feedback/ack
  def create
    return head :bad_request unless FeedbackExchangeAck.record_all(consumer: exchange_consumer, items: items)

    head :no_content
  end

  private

  # @return [Array<Hash>] the posted items, each reduced to the fields we store
  def items
    raw = params[:items]
    raise ActionController::BadRequest, "items must be a list" unless raw.is_a?(Array)

    raw.map do |item|
      raise ActionController::BadRequest, "each item must be an object" unless item.respond_to?(:permit)

      item.permit(:id, :remote_id, :remote_url).to_h.symbolize_keys
    end
  end
end
