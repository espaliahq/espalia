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
  # How long an external channel waits for the recipient to read the in-app
  # notification before delivering, to avoid duplicate pings ("smart
  # notification"). Applied only when the recipient surfaces this type in-app.
  ESCALATION_DELAY = 5.minutes

  # Longest quoted free-text excerpt (a response body, a decline reason) a
  # notification body will carry — see `quoted_excerpt`.
  EXCERPT_LIMIT = 280

  # The NotificationType key this notifier delivers. Set via `notifies`.
  class_attribute :notification_type_key, instance_writer: false

  # Bind this notifier to a NotificationType.
  #
  # @param type_key [Symbol, String]
  def self.notifies(type_key)
    self.notification_type_key = type_key.to_sym
  end

  # External Slack DM, gated by the smart-escalation rules. Fires only when the
  # recipient enabled Slack for this type and (when they also get it in-app)
  # hasn't read the in-app copy within ESCALATION_DELAY. Notifiers must include
  # `tenant_id` in their params so the delivery method can resolve the
  # per-tenant workspace + recipient identity.
  deliver_by :slack, class: "SlackDeliveryMethod" do |config|
    config.wait = -> { external_wait }
    config.if = -> { escalate_external?(:slack) }
  end

  # Smart-escalation helpers shared by every external delivery method. They run
  # in the context of a Noticed::Notification (recipient + read state + event
  # available) and are evaluated at delivery time, so the read check reflects
  # the moment the delayed job runs.
  #
  # An external `deliver_by` wires them as:
  #   config.wait = -> { external_wait }
  #   config.if   = -> { escalate_external?(:slack) }
  notification_methods do
    # Whether to deliver this notification over an external channel now.
    #
    # - false unless the recipient enabled this type on that channel,
    # - true immediately when the recipient has the in-app channel disabled
    #   (no in-app copy to read, so no duplication to avoid),
    # - otherwise only when the in-app notification is still unread.
    #
    # @param channel [Symbol] :slack / :email
    # @return [Boolean]
    def escalate_external?(channel)
      key = event.class.notification_type_key
      return false unless recipient.respond_to?(:notifies_via?)
      return false unless recipient.notifies_via?(key, channel)
      return true unless recipient.notifies_via?(key, :in_app)

      unread?
    end

    # How long to wait before attempting external delivery: the escalation
    # delay when the recipient also gets this in-app (give them a chance to
    # read it first), otherwise no wait.
    #
    # @return [ActiveSupport::Duration, Integer]
    def external_wait
      key = event.class.notification_type_key
      if recipient.respond_to?(:notifies_via?) && recipient.notifies_via?(key, :in_app)
        ApplicationNotifier::ESCALATION_DELAY
      else
        0
      end
    end
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

    private

    # Free text someone wrote (an evidence response, a decline reason), quoted
    # for a notification body and truncated so a long write-up doesn't flood
    # Slack or the inbox — the deep link carries the reader to the full text.
    #
    # @param text [String, nil]
    # @return [String, nil] nil when there is nothing to quote
    def quoted_excerpt(text)
      text = text.to_s.strip
      return nil if text.blank?

      "“#{text.truncate(ApplicationNotifier::EXCERPT_LIMIT, omission: "…")}”"
    end
  end
end
