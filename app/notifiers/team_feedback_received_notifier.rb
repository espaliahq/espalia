# frozen_string_literal: true

# Tells the manager side that someone recorded feedback on a report's
# assessment — placed on a capability, or waiting to be placed.
class TeamFeedbackReceivedNotifier < ApplicationNotifier
  notifies :team_feedback_received

  notification_methods do
    def inbox_title
      who = params[:author_name].presence || "A colleague"
      whom = params[:assessee_name].presence || "your report"
      params[:placed] ? "#{who} gave #{whom} feedback" : "#{who} gave #{whom} feedback to place"
    end

    def inbox_body
      labeled_excerpt(params[:context], params[:content])
    end

    def inbox_url = params[:url]
  end
end
