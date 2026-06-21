# frozen_string_literal: true

# Full-page in-app notification inbox.
class Views::Notifications::IndexView < Views::Base
  # @param notifications [Array<Noticed::Notification>] surfaced, newest first
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(notifications:, user: nil, current_tenant: nil, tenants: [])
    @notifications = notifications
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-2xl mx-auto") do
        page_header
        @notifications.any? ? list : empty_state
      end
    end
  end

  private

  def page_header
    div(class: "flex items-center justify-between mb-6") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Notifications" }
      if @notifications.any?(&:unread?)
        a(
          href: read_all_notifications_path,
          data: { turbo_method: :post },
          class: "text-sm font-medium text-blue-600 hover:underline min-h-11 inline-flex items-center"
        ) { "Mark all as read" }
      end
    end
  end

  def list
    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 divide-y divide-gray-100 dark:divide-gray-800 overflow-hidden") do
      @notifications.each { |n| render Views::Notifications::Row.new(notification: n) }
    end
  end

  def empty_state
    div(class: "rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-10 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { "You're all caught up — no notifications yet." }
    end
  end
end
