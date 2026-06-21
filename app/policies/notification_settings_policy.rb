# frozen_string_literal: true

# Authorization for a user's own notification preferences page.
#
# Headless symbol policy: `authorize :notification_settings, :show?`.
# Preferences are personal and cross-tenant — any signed-in user may view and
# edit their own; there is no admin override.
class NotificationSettingsPolicy < ApplicationPolicy
  # @return [Boolean]
  def show?   = user.present?

  # @return [Boolean]
  def update? = user.present?
end
