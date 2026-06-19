# frozen_string_literal: true

# Navbar notification bell — a lazy Turbo Frame whose content is re-fetched
# live (via notifications_sync_controller) whenever a new in-app notification
# lands. Shows an unread-count badge.
class Views::Notifications::Bell < Views::Base
  # @param unread_count [Integer]
  def initialize(unread_count:)
    @unread_count = unread_count.to_i
  end

  def view_template
    turbo_frame_tag("notification-bell") do
      a(
        href: notifications_path,
        class: "relative inline-flex items-center justify-center h-11 w-11 rounded-md " \
               "text-nav-fg/80 hover:text-nav-fg hover:bg-white/10 " \
               "focus:outline-hidden focus:ring-2 focus:ring-white",
        aria: { label: aria_label }
      ) do
        bell_icon
        unread_badge if @unread_count.positive?
      end
    end
  end

  private

  def aria_label
    @unread_count.positive? ? "Notifications, #{@unread_count} unread" : "Notifications"
  end

  def bell_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "h-5 w-5",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      aria: { hidden: "true" }
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        stroke_width: "2",
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
