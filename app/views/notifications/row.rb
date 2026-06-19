# frozen_string_literal: true

# One row in the notification inbox. Clicking marks the notification read
# (PATCH via Turbo) and navigates to its target surface.
class Views::Notifications::Row < Views::Base
  # @param notification [Noticed::Notification]
  def initialize(notification:)
    @notification = notification
  end

  def view_template
    a(
      href: notification_path(@notification),
      # turbo_frame _top so a row inside the lazy bell frame drives a full-page
      # navigation (mark read + go to target) rather than navigating the frame.
      data: { turbo_method: :patch, turbo_frame: "_top" },
      class: row_classes
    ) do
      unread_dot
      div(class: "min-w-0 flex-1") do
        p(class: "text-sm font-medium text-gray-900 dark:text-white truncate") { title }
        p(class: "mt-0.5 text-sm text-gray-600 dark:text-gray-300 line-clamp-2") { body } if body.present?
        p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") { local_time_ago(@notification.created_at) }
      end
    end
  end

  private

  def title
    @notification.inbox_title
  end

  def body
    @notification.inbox_body
  end

  def row_classes
    base = "flex items-start gap-3 px-4 py-3 min-h-11 transition-colors " \
           "hover:bg-gray-50 dark:hover:bg-gray-800/60 focus:outline-hidden focus:ring-2 focus:ring-blue-600"
    base += " bg-blue-50/60 dark:bg-blue-900/10" if @notification.unread?
    base
  end

  def unread_dot
    div(class: "shrink-0 pt-1.5") do
      if @notification.unread?
        span(class: "block h-2 w-2 rounded-full bg-blue-600", aria: { hidden: "true" })
      else
        span(class: "block h-2 w-2", aria: { hidden: "true" })
      end
    end
  end
end
