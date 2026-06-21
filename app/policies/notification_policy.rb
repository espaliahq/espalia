# frozen_string_literal: true

# Authorization for a user's own in-app notification inbox.
#
# Notifications are private to their recipient: collection actions require any
# signed-in user (the controller always scopes to `current_user`), and member
# actions require the notification to belong to the acting user. There is no
# admin override — notifications are personal, not tenant-administered.
class NotificationPolicy < ApplicationPolicy
  # GET /notifications
  def index?
    user.present?
  end

  # GET /notifications/bell
  def bell?
    user.present?
  end

  # POST /notifications/read_all
  def read_all?
    user.present?
  end

  # PATCH /notifications/:id
  def update?
    user.present? && record.respond_to?(:recipient_id) && record.recipient_id == user.id
  end
end
