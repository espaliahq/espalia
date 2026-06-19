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
      "#{params[:requester_name].presence || "A colleague"} asked you for evidence"
    end

    def inbox_body
      [ params[:capability_name].presence, params[:message].presence ].compact.join(" — ").presence
    end

    def inbox_url = "/evidence"
  end
end
