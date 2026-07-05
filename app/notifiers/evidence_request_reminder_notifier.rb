# frozen_string_literal: true

# Nudges the requestee about a still-pending evidence request — either it has
# sat unanswered (`kind: "no_response"`) or its due date is approaching
# (`kind: "due_soon"`).
#
# Fired by the async handler off EvidenceRequestReminderSent (which the
# reminder sweep job emits at most once per kind per request). Delivered
# in-app immediately and over Slack after the escalation delay if unread, per
# the recipient's `evidence_request_reminder` preferences. The deep link lands
# on the hub card where responding AND declining are both one click — a
# decline closes the loop just as well as feedback does.
class EvidenceRequestReminderNotifier < ApplicationNotifier
  notifies :evidence_request_reminder

  notification_methods do
    def inbox_title
      requester = params[:requester_name].presence || "A colleague"
      regarding = params[:assessee_name].present? ? " regarding #{params[:assessee_name]}" : ""
      if params[:kind] == "due_soon"
        "Reminder: #{requester}'s feedback request#{regarding} is due #{due_phrase}"
      else
        "Reminder: #{requester} is still waiting on your feedback#{regarding}"
      end
    end

    def inbox_body
      capability = params[:capability_name].presence
      lead = "The request is for behavioural feedback#{capability ? " for #{capability}" : ""}"
      [ lead, params[:message].presence ].compact.join(" — ")
    end

    def inbox_url = EvidenceRequest.hub_path(params[:request_id])

    private

    # @return [String] the due date as "Tue 7 Jul", or "soon" if unparseable
    def due_phrase
      due = Time.zone.parse(params[:due_at].to_s)
      due ? due.strftime("%a %-d %b") : "soon"
    rescue ArgumentError
      "soon"
    end
  end
end
