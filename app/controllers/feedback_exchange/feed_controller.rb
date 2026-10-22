# frozen_string_literal: true

# The producer feed (GET /api/feedback_exchange/feedback), protocol §5.1.
class FeedbackExchange::FeedController < ActionController::Base
  include FeedbackExchangeProducer

  # GET /api/feedback_exchange/feedback?since=&limit=
  def show
    page = FeedbackExchange::Feed.new(
      consumer: exchange_consumer,
      config: exchange_config,
      cursor: FeedbackExchange::FeedCursor.decode(params[:since]),
      limit: limit
    ).page

    render json: { items: page.items, next_cursor: page.next_cursor, has_more: page.has_more }
  end

  private

  # @return [Integer] the requested page size; a missing one is the default
  def limit
    return FeedbackExchange::Feed::DEFAULT_LIMIT if params[:limit].blank?

    value = Integer(params[:limit].to_s, 10)
    raise ActionController::BadRequest, "limit must be positive" unless value.positive?

    value
  rescue ArgumentError
    raise ActionController::BadRequest, "limit must be an integer"
  end
end
