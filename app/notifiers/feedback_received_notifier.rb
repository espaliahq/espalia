# frozen_string_literal: true

# Tells the recipient that someone recorded feedback on their assessment —
# placed on a capability, or waiting for them to place it.
class FeedbackReceivedNotifier < ApplicationNotifier
  notifies :feedback_received

  notification_methods do
    def inbox_title
      who = params[:author_name].presence || "A colleague"
      params[:placed] ? "#{who} gave you feedback" : "#{who} gave you feedback to place"
    end

    def inbox_body
      labeled_excerpt(params[:context], params[:content])
    end

    def inbox_url = params[:url]
  end
end
