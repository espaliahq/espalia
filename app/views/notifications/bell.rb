# frozen_string_literal: true

# Navbar notification bell — a lazy Turbo Frame whose content is re-fetched
# live (via notifications_sync_controller) whenever a new in-app notification
# lands. The icon opens a dropdown panel previewing recent notifications;
# "View all" links to the full inbox page.
class Views::Notifications::Bell < Views::Base
  # @param notifications [Array<Noticed::Notification>] recent, newest first
  # @param unread_count [Integer]
  def initialize(notifications: [], unread_count: 0)
    @notifications = notifications
    @unread_count = unread_count.to_i
  end

  def view_template
    turbo_frame_tag("notification-bell") do
      div(class: "relative", data: { controller: "dropdown", action: "keydown.esc@window->dropdown#close" }) do
        trigger
        panel
      end
    end
  end

  private

  def trigger
    button(
      type: "button",
      data: { action: "dropdown#toggle", dropdown_target: "trigger" },
      aria: { haspopup: "true", expanded: "false", label: aria_label },
      class: "relative inline-flex items-center justify-center h-11 w-11 rounded-md " \
             "text-nav-fg/80 hover:text-nav-fg hover:bg-white/10 " \
             "focus:outline-hidden focus:ring-2 focus:ring-white cursor-pointer"
    ) do
      bell_icon
      unread_badge if @unread_count.positive?
    end
  end

  def panel
    div(
      class: "absolute right-0 mt-2 w-80 max-w-[calc(100vw-1rem)] rounded-md shadow-lg " \
             "bg-white dark:bg-gray-800 ring-1 ring-black/5 dark:ring-white/10 z-50 hidden overflow-hidden",
      data: { dropdown_target: "menu" },
      role: "menu",
      aria: { orientation: "vertical", label: "Notifications" }
    ) do
      panel_header
      @notifications.any? ? panel_list : panel_empty
      panel_footer
    end
  end

  def panel_header
    div(class: "flex items-center justify-between px-4 py-2.5 border-b border-gray-100 dark:border-gray-700") do
      span(class: "text-sm font-semibold text-gray-900 dark:text-white") { "Notifications" }
      if @unread_count.positive?
        a(
          href: read_all_notifications_path,
          data: { turbo_method: :post, turbo_frame: "_top" },
          class: "text-xs font-medium text-blue-600 hover:underline"
        ) { "Mark all read" }
      end
    end
  end

  def panel_list
    div(class: "max-h-96 overflow-y-auto divide-y divide-gray-100 dark:divide-gray-700") do
      @notifications.each { |n| render Views::Notifications::Row.new(notification: n) }
    end
  end

  def panel_empty
    div(class: "px-4 py-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { "You're all caught up." }
    end
  end

  def panel_footer
    div(class: "border-t border-gray-100 dark:border-gray-700") do
      a(
        href: notifications_path,
        data: { turbo_frame: "_top" },
        class: "block px-4 py-2.5 text-center text-sm font-medium text-blue-600 hover:bg-gray-50 dark:hover:bg-gray-700/50"
      ) { "View all notifications" }
    end
  end

  def aria_label
    @unread_count.positive? ? "Notifications, #{@unread_count} unread" : "Notifications"
  end

  def bell_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg", class: "h-5 w-5", fill: "none",
      viewBox: "0 0 24 24", stroke: "currentColor", aria: { hidden: "true" }
    ) do |s|
      s.path(
        stroke_linecap: "round", stroke_linejoin: "round", stroke_width: "2",
        d: "M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
      )
    end
  end

  def unread_badge
    span(
      class: "absolute -top-0.5 -right-0.5 inline-flex items-center justify-center " \
             "min-w-4 h-4 px-1 rounded-full bg-red-600 text-white text-[10px] font-semibold leading-none"
    ) { @unread_count > 99 ? "99+" : @unread_count.to_s }
  end
end
