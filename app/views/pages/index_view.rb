# frozen_string_literal: true

# Root dashboard view.
#
# Uses the shared PageLayout component for the Navbar + Sidebar shell.
#
class Views::Pages::IndexView < Views::Base
  # @param user [User, nil] the currently signed-in user
  # @param current_tenant [Tenant, nil] the active tenant
  # @param tenants [Array<Tenant>] all tenants the user belongs to
  def initialize(user: nil, current_tenant: nil, tenants: [])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white mb-6") { "Welcome to GrowthOS" }
      stat_cards
    end
  end

  private

  def stat_cards
    div(class: "grid grid-cols-1 sm:grid-cols-3 gap-6") do
      stat_card("Streak", "0 days", "Track your daily activity")
      stat_card("Points", "0", "Earn points by completing tasks")
      stat_card("Goals", "0", "Set and track your goals")
    end
  end

  def stat_card(label, value, description)
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm font-medium text-gray-500 dark:text-gray-400") { label }
        p(class: "mt-2 text-3xl font-bold text-gray-900 dark:text-white") { value }
        p(class: "mt-1 text-sm text-gray-500 dark:text-gray-400") { description }
      end
    end
  end
end
