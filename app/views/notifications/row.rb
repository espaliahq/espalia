# frozen_string_literal: true

# One row in the notification inbox. Clicking marks the notification read and
# navigates to its target surface.
#
# Submitted as a NATIVE (data-turbo=false) PATCH form, not a Turbo link: the
# controller redirects to the notification's target, which may carry a #anchor
# (e.g. /evidence#evidence-request-<id>). Turbo follows redirects via fetch,
# whose response URL strips the fragment — a native submit lets the browser
# follow the 302 with the anchor intact and scroll to it.
class Views::Notifications::Row < Views::Base
  # @param notification [Noticed::Notification]
  def initialize(notification:)
    @notification = notification
  end

  def view_template
    form(action: notification_path(@notification), method: "post", data: { turbo: "false" }, class: "block") do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(type: "submit", class: "#{row_classes} w-full text-left cursor-pointer") do
        unread_dot
        div(class: "min-w-0 flex-1") do
          p(class: "text-sm font-medium text-gray-900 dark:text-white break-words") { title }
          p(class: "mt-0.5 text-sm text-gray-600 dark:text-gray-300 break-words whitespace-pre-line") { body } if body.present?
          p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") { local_time_ago(@notification.created_at) }
        end
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
