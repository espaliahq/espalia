# frozen_string_literal: true

class AddExternalNotificationsDisclosedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :external_notifications_disclosed_at, :datetime
  end
end
