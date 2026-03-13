# frozen_string_literal: true

# Root dashboard shell view.
#
# Composes the Navbar and Sidebar Kit components into a responsive layout.
# On mobile, the sidebar is hidden by default and toggled via the sidebar
# Stimulus controller. On md+ screens the sidebar is always visible.
class Views::Pages::IndexView < Views::Base
  NAV_LINKS = [
    { label: "Home", href: "/" }
  ].freeze

  def view_template
    div(
      class: "min-h-screen flex flex-col bg-gray-50 dark:bg-gray-950",
      data: { controller: "sidebar" }
    ) do
      render Components::Kit::Navbar.new(app_name: "GrowthOS")

      div(class: "flex flex-1") do
        render Components::Kit::Sidebar.new(links: NAV_LINKS)
        main_content
      end
    end
  end

  private

  def main_content
    main(class: "flex-1 p-6 overflow-auto") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white mb-6") { "Welcome to GrowthOS" }
      stat_cards
    end
  end

  def stat_cards
    div(class: "grid grid-cols-1 sm:grid-cols-3 gap-6") do
      stat_card("Streak", "0 days", "Track your daily activity")
      stat_card("Points", "0", "Earn points by completing tasks")
      stat_card("Goals", "0", "Set and track your goals")
    end
  end

  def stat_card(label, value, description)
    div(class: "bg-white dark:bg-gray-800 rounded-lg shadow-sm border border-gray-200 dark:border-gray-700 p-6") do
      p(class: "text-sm font-medium text-gray-500 dark:text-gray-400") { label }
      p(class: "mt-2 text-3xl font-bold text-gray-900 dark:text-white") { value }
      p(class: "mt-1 text-sm text-gray-500 dark:text-gray-400") { description }
    end
  end
end
