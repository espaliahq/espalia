# frozen_string_literal: true

# A Noticed notification belongs to exactly one event; orphaning a notification
# from its event would break inbox rendering (it reads params off the event).
# The original create migration is already applied locally, so the FK + cascade
# lands here. delete: :cascade matches Noticed's lifecycle — destroying an event
# destroys its notifications.
class AddEventFkToNoticedNotifications < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :noticed_notifications, :noticed_events, column: :event_id, on_delete: :cascade
  end
end
