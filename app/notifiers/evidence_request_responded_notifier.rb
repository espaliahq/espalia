# frozen_string_literal: true

# Notifies the original requester that their evidence request was answered,
# carrying the response itself (quoted, excerpted) so the Slack DM / inbox row
# reads the feedback without a round trip to the hub.
class EvidenceRequestRespondedNotifier < ApplicationNotifier
  notifies :evidence_request_responded

  notification_methods do
    def inbox_title
      "#{params[:responder_name].presence || "A colleague"} answered your feedback request"
    end

    def inbox_body
      labeled_excerpt(params[:capability_name], params[:response])
    end

    def inbox_url = EvidenceRequest.hub_path(params[:request_id])
  end
end
