# frozen_string_literal: true

# Base class for every Noticed notifier in the app.
#
# Responsibilities shared by all notifiers:
#   - bind the notifier to a {NotificationType} key (drives preference gating
#     and the settings UI) via `notifies :some_type`,
#   - expose a uniform presentation interface the in-app inbox renders from
#     (`inbox_title`, `inbox_body`, `inbox_url`), overridable per notifier.
#
# Delivery methods (Slack, email) are declared by subclasses or in a later
# phase; the in-app channel needs no `deliver_by` — the Noticed::Notification
# record is created by `deliver` and surfaced by NotificationInbox.
#
# @example
#   class EvidenceRequestNotifier < ApplicationNotifier
#     notifies :evidence_requested
#     notification_methods do
#       def inbox_title = "#{params[:requester_name]} asked you for evidence"
#     end
#   end
class ApplicationNotifier < Noticed::Event
  # The NotificationType key this notifier delivers. Set via `notifies`.
  class_attribute :notification_type_key, instance_writer: false

  # Bind this notifier to a NotificationType.
  #
  # @param type_key [Symbol, String]
  def self.notifies(type_key)
    self.notification_type_key = type_key.to_sym
  end

  # Presentation interface consumed by the in-app inbox. Methods run in the
  # context of a Noticed::Notification (params/record/recipient available);
  # subclasses override as needed.
  notification_methods do
    # @return [String] one-line headline for the inbox row + Slack/email subject
    def inbox_title
      params[:title].to_s
    end

    # @return [String, nil] supporting detail for the inbox row
    def inbox_body
      params[:body].presence
    end

    # @return [String] where the inbox row links to (the actionable surface)
    def inbox_url
      params[:url].presence || "/"
    end
  end
end
