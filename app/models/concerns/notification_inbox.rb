# frozen_string_literal: true

# Mixed into Noticed::Notification (via the noticed_notification load hook in
# config/initializers/noticed.rb) to add the in-app inbox behaviour:
#
#   - resolve the originating notifier's NotificationType key,
#   - decide whether the recipient surfaces this notification in-app,
#   - nudge the recipient's notification Turbo stream on create so the bell /
#     inbox refresh live.
#
# The live update follows the app's signal-element convention (see
# broadcast_assessment_sync): we replace a tiny per-user signal element and let
# `notifications_sync_controller` reload the bell frame — no background Phlex
# rendering required.
module NotificationInbox
  extend ActiveSupport::Concern

  # Stream name + signal target shared with the navbar/bell view.
  SIGNAL_DOM_ID = "notifications-sync-signal"

  included do
    after_create_commit :broadcast_inbox_signal
  end

  # The NotificationType key of the notifier that produced this notification,
  # or nil for notifications not produced by an ApplicationNotifier.
  #
  # @return [Symbol, nil]
  def notifier_type_key
    klass = event&.class
    klass.respond_to?(:notification_type_key) ? klass.notification_type_key : nil
  end

  # Whether the recipient wants this notification shown in their in-app inbox.
  # Unknown notifier types surface by default; a recipient that can't express
  # preferences (non-User) also surfaces by default.
  #
  # @return [Boolean]
  def surfaced_in_app?
    key = notifier_type_key
    return true if key.nil?
    return true unless recipient.respond_to?(:notifies_via?)

    recipient.notifies_via?(key, :in_app)
  end

  # @return [String] the in-app stream name for a recipient
  def self.stream_for(recipient)
    [ recipient, :notifications ]
  end

  private

  def broadcast_inbox_signal
    return unless surfaced_in_app?

    Turbo::StreamsChannel.broadcast_replace_to(
      NotificationInbox.stream_for(recipient),
      target: SIGNAL_DOM_ID,
      html: %(<div id="#{SIGNAL_DOM_ID}" data-notifications-sync-target="signal" hidden data-ts="#{Time.current.to_f}"></div>)
    )
  end
end
