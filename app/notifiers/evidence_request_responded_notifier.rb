# frozen_string_literal: true

# Notifies the original requester that their evidence request was answered.
class EvidenceRequestRespondedNotifier < ApplicationNotifier
  notifies :evidence_request_responded

  notification_methods do
    def inbox_title
      "#{params[:responder_name].presence || "A colleague"} answered your evidence request"
    end

    def inbox_body = params[:capability_name].presence

    def inbox_url = "/evidence"
  end
end
