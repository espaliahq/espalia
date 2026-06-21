# frozen_string_literal: true

# A user's own notification preferences — a type × channel matrix of
# overrides on top of the code-defined defaults in {NotificationType}.
# Cross-tenant (they live on the global User), so this page is identical
# regardless of the active workspace.
class Settings::NotificationsController < ApplicationController
  # Channels exposed in the UI. Email is modelled but not yet delivered
  # (wired in a later phase), so it's omitted here until it does something.
  UI_CHANNELS = %i[in_app slack].freeze

  # GET /settings/notifications
  def show
    authorize :notification_settings, :show?
    render Views::Settings::Notifications::ShowView.new(
      types: NotificationType.all,
      channels: UI_CHANNELS,
      enabled: current_enabled_matrix,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # PATCH /settings/notifications
  def update
    authorize :notification_settings, :update?
    submitted = params.fetch(:notification_preferences, {})

    NotificationType.all.each do |type|
      channels = UI_CHANNELS.index_with { |channel| submitted.dig(type.key.to_s, channel.to_s) }
      current_user.update_notification_preference(type.key, channels)
    end

    redirect_to settings_notifications_path, notice: "Notification preferences saved."
  end

  private

  # @return [Hash{Symbol => Hash{Symbol => Boolean}}] effective state per type/channel
  def current_enabled_matrix
    NotificationType.all.each_with_object({}) do |type, matrix|
      matrix[type.key] = UI_CHANNELS.index_with { |channel| current_user.notifies_via?(type.key, channel) }
    end
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
