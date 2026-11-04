# frozen_string_literal: true

# Which feedback messages a user hasn't read, read from the in-app
# notifications we already send for them (#647). A message is unread while
# its notification is; opening its conversation marks the notification read,
# which clears the navbar bell too. Messages that never notified anyone
# (anything before notifications existed, self feedback, imports) read as
# read.
#
# Read state lives here, not in the event stream: it belongs to the reader,
# not to anyone's development history.
#
# Item notifications carry the item as their record. Request notifications
# carry only `request_id` in their params, so they are matched on that.
class Evidence::ConversationReads
  REQUEST_NOTIFIERS = {
    "EvidenceRequestedNotifier" => "request",
    "EvidenceRequestReminderNotifier" => "request",
    "EvidenceRequestRespondedNotifier" => "replied",
    "EvidenceRequestDeclinedNotifier" => "declined"
  }.freeze
  ITEM_NOTIFIERS = %w[FeedbackReceivedNotifier TeamFeedbackReceivedNotifier].freeze

  # @param user [User]
  def initialize(user)
    @user = user
  end

  # @return [Set<String>] {Evidence::Conversations::Message#read_keys} with an
  #   unread notification
  def unread_keys
    @unread_keys ||= unread_rows.to_set { |_id, key| key }
  end

  # @param message [Evidence::Conversations::Message]
  # @return [Boolean]
  def unread?(message) = message.read_keys.any? { |key| unread_keys.include?(key) }

  # Marks the notifications behind these messages read.
  #
  # @param messages [Array<Evidence::Conversations::Message>]
  # @return [Integer] how many notifications changed
  def mark_read!(messages)
    keys = messages.flat_map(&:read_keys).to_set
    ids = unread_rows.filter_map { |id, key| id if keys.include?(key) }
    return 0 if ids.empty?

    @unread_keys = nil
    @unread_rows = nil
    now = Time.current
    Noticed::Notification.where(id: ids).update_all([ "read_at = ?, seen_at = COALESCE(seen_at, ?)", now, now ])
  end

  private

  def unread_rows
    @unread_rows ||= Noticed::Notification.joins(:event)
      .where(recipient: @user, read_at: nil, noticed_events: { type: REQUEST_NOTIFIERS.keys + ITEM_NOTIFIERS })
      .pluck(:id, "noticed_events.type", Arel.sql("noticed_events.params->>'request_id'"), "noticed_events.record_id")
      .filter_map do |id, type, request_id, record_id|
        if ITEM_NOTIFIERS.include?(type)
          [ id, "item:#{record_id}" ] if record_id
        elsif request_id
          [ id, "#{REQUEST_NOTIFIERS[type]}:#{request_id}" ]
        end
      end
  end
end
