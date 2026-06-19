# frozen_string_literal: true

# Notifies the original requester that their evidence request was declined.
class EvidenceRequestDeclinedNotifier < ApplicationNotifier
  notifies :evidence_request_declined

  notification_methods do
    def inbox_title
      "#{params[:decliner_name].presence || "A colleague"} declined your evidence request"
    end

    def inbox_body
      [ params[:capability_name].presence, params[:reason].presence ].compact.join(" — ").presence
    end

    def inbox_url = "/evidence"
  end
end
