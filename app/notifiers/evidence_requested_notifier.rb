# frozen_string_literal: true

# Notifies the requestee that someone asked them for evidence.
#
# Delivered in-app immediately and over Slack after the escalation delay if
# unread (per the recipient's preferences). The async handler that fires this
# supplies the presentation params + tenant_id (for Slack resolution).
class EvidenceRequestedNotifier < ApplicationNotifier
  notifies :evidence_requested

  notification_methods do
    def inbox_title
      base = "#{params[:requester_name].presence || "A colleague"} asked you for feedback"
      params[:assessee_name].present? ? "#{base} regarding #{params[:assessee_name]}" : base
    end

    def inbox_body
      capability = params[:capability_name].presence
      lead = "The request is for behavioural feedback#{capability ? " for #{capability}" : ""}"
      [ lead, params[:message].presence ].compact.join(" — ")
    end

    def inbox_url = EvidenceRequest.hub_path(params[:request_id])
  end
end
