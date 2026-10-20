# frozen_string_literal: true

# Asks the manager side to place feedback that arrived from a peer system
# without a capability: the peer already told the recipient it was given, so
# this is a request for an action, not news of an arrival (protocol §2.6).
class FeedbackPlacementNotifier < ApplicationNotifier
  notifies :feedback_to_place

  notification_methods do
    def inbox_title
      who = params[:author_name].presence || "A colleague"
      whom = params[:assessee_name].presence || "your report"
      "#{who} gave #{whom} feedback in #{params[:peer_label].presence || 'another system'}"
    end

    def inbox_body
      labeled_excerpt("Confirm which capabilities it speaks to and what it shows", params[:content])
    end

    def inbox_url = params[:url]
  end
end
