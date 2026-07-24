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
    # right-0 anchors to the bell, which is not at the viewport edge — on a
    # narrow screen a 20rem panel would spill off-screen left, so below `sm`
    # it goes fixed and spans the viewport (minus gutters) instead.
    div(
      class: "absolute right-0 mt-2 w-80 max-w-[calc(100vw-1rem)] rounded-md shadow-lg " \
             "max-sm:fixed max-sm:inset-x-2 max-sm:top-14 max-sm:mt-0 max-sm:w-auto max-sm:max-w-none " \
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
      div(class: "flex items-center gap-1") do
        if @unread_count.positive?
          a(
            href: read_all_notifications_path,
            data: { turbo_method: :post, turbo_frame: "_top" },
            class: "text-xs font-medium text-blue-600 hover:underline"
          ) { "Mark all read" }
        end
        preferences_link
      end
    end
  end

  # Icon-only link to the notification preferences page. 44px hit area via
  # negative margins so the compact header height is unchanged.
  def preferences_link
    a(
      href: settings_notifications_path,
      data: { turbo_frame: "_top" },
      aria: { label: "Notification preferences" },
      class: "inline-flex items-center justify-center h-11 w-11 -my-3 -mr-2 rounded-md " \
             "text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white " \
             "hover:bg-gray-100 dark:hover:bg-gray-700/50"
    ) { gear_icon }
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

  def gear_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg", class: "h-4 w-4", fill: "none",
      viewBox: "0 0 24 24", stroke: "currentColor", aria: { hidden: "true" }
    ) do |s|
      s.path(
        stroke_linecap: "round", stroke_linejoin: "round", stroke_width: "1.8",
        d: "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.324.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.431.992a6.759 6.759 0 010 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.02-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281z"
      )
      s.path(
        stroke_linecap: "round", stroke_linejoin: "round", stroke_width: "1.8",
        d: "M15 12a3 3 0 11-6 0 3 3 0 016 0z"
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
