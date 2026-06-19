# frozen_string_literal: true

# The current user's in-app notification inbox.
#
# Notifications live on the global User (cross-tenant), so this controller is
# not tenant-scoped beyond what the navbar needs. Only notifications the user
# surfaces in-app (per their NotificationType preferences) are shown; the
# underlying Noticed::Notification rows always exist as the escalation anchor.
class NotificationsController < ApplicationController
  # How many recent notifications the inbox/bell consider. The in-app/surfaced
  # filter runs in Ruby, so we bound the working set.
  RECENT_LIMIT = 100

  # GET /notifications
  def index
    authorize Noticed::Notification, :index?, policy_class: NotificationPolicy
    surfaced = surfaced_notifications
    mark_seen(surfaced)

    render Views::Notifications::IndexView.new(
      notifications: surfaced,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /notifications/bell — lazy Turbo Frame content for the navbar bell.
  def bell
    authorize Noticed::Notification, :bell?, policy_class: NotificationPolicy
    render Views::Notifications::Bell.new(unread_count: surfaced_notifications.count(&:unread?))
  end

  # PATCH /notifications/:id — mark one read, then go to its target surface.
  # Found globally then authorized (defense in depth) so a cross-user attempt
  # is a Pundit denial, not a silent 404.
  def update
    notification = Noticed::Notification.find(params[:id])
    authorize notification, policy_class: NotificationPolicy
    notification.mark_as_read
    redirect_to safe_inbox_url(notification)
  end

  # POST /notifications/read_all
  def read_all
    authorize Noticed::Notification, :read_all?, policy_class: NotificationPolicy
    current_user.notifications.unread.mark_as_read
    redirect_back fallback_location: notifications_path, notice: "All notifications marked as read."
  end

  private

  # Recent notifications the user surfaces in-app, newest first.
  #
  # Scoped to STI types whose notifier class is still defined: a removed,
  # renamed, or otherwise unloadable notifier must never 500 the always-on
  # navbar bell (ActiveRecord raises SubclassNotFound while materialising an
  # unknown `type`). Such rows are simply omitted.
  #
  # @return [Array<Noticed::Notification>]
  def surfaced_notifications
    @surfaced_notifications ||= current_user.notifications
      .where(type: known_notification_types)
      .includes(:event)
      .newest_first
      .limit(RECENT_LIMIT)
      .select(&:surfaced_in_app?)
  end

  # @return [Array<String>] notification STI type names with a loadable notifier
  def known_notification_types
    ApplicationNotifier.descendants.map { |klass| "#{klass}::Notification" }
  end

  def mark_seen(notifications)
    unseen_ids = notifications.select(&:unseen?).map(&:id)
    Noticed::Notification.where(id: unseen_ids).mark_as_seen if unseen_ids.any?
  end

  # The notifier-provided target URL, restricted to a same-origin relative path
  # so a crafted params payload can never become an open redirect.
  #
  # @return [String]
  def safe_inbox_url(notification)
    url = notification.inbox_url.to_s
    url.start_with?("/") && !url.start_with?("//") ? url : notifications_path
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
