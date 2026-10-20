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
    render Components::Shell::PageLayout.new(
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
      h1(class: "text-2xl font-bold text-default") { "Notifications" }
      if @notifications.any?(&:unread?)
        a(
          href: read_all_notifications_path,
          data: { turbo_method: :post },
          class: "text-sm font-medium text-link hover:underline min-h-11 inline-flex items-center"
        ) { "Mark all as read" }
      end
    end
  end

  def list
    render Components::Kit::Card.new(variant: :flush) do
      div(class: "divide-y divide-subtle") do
        @notifications.each { |n| render Views::Notifications::Row.new(notification: n) }
      end
    end
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "You're all caught up — no notifications yet.")
  end
end
