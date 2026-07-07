# frozen_string_literal: true

# Notifies the original requester that their evidence request was declined,
# carrying the decliner's reason (quoted, excerpted) so the Slack DM / inbox
# row reads the response without a round trip to the hub.
class EvidenceRequestDeclinedNotifier < ApplicationNotifier
  notifies :evidence_request_declined

  notification_methods do
    def inbox_title
      "#{params[:decliner_name].presence || "A colleague"} declined your feedback request"
    end

    def inbox_body
      labeled_excerpt(params[:capability_name], params[:reason])
    end

    def inbox_url = EvidenceRequest.hub_path(params[:request_id])
  end
end
