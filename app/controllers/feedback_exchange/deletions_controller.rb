# frozen_string_literal: true

# The deletions feed (GET /api/feedback_exchange/feedback/deletions), protocol
# §5.2. GrowthOS withdraws feedback and never deletes it, so the withdrawal
# rides the main feed as `status: "withdrawn"` and this feed is always empty.
class FeedbackExchange::DeletionsController < ActionController::Base
  include FeedbackExchangeProducer

  # GET /api/feedback_exchange/feedback/deletions?since=&limit=
  def show
    render json: { items: [], next_cursor: params[:since].presence, has_more: false }
  end
end
