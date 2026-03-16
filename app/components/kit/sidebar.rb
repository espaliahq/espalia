# frozen_string_literal: true

# Mobile-only navigation drawer.
#
# Hidden by default — toggled by the sidebar Stimulus controller's
# hamburger button. On desktop, nav links are in the Navbar instead.
#
# @example
#   render Components::Kit::Sidebar.new(links: [
#     { label: "Home", href: "/" },
#     { label: "Reports", href: "/reports" }
#   ])
class Components::Kit::Sidebar < Components::Base
  # @param links [Array<Hash>] Navigation links, each with :label and :href keys
  def initialize(links:)
    @links = links
  end

  def view_template
    aside(
      class: "hidden fixed inset-y-0 left-0 z-40 w-64 bg-gray-900 text-gray-100 md:hidden",
      data: { sidebar_target: "drawer" }
    ) do
      nav(class: "flex flex-col gap-1 p-4 pt-20 flex-1", aria: { label: "Mobile navigation" }) do
        @links.each { |link| nav_link(link) }
      end
    end
  end

  private

  def nav_link(link)
    a(
      href: link[:href],
      class: "flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium " \
             "text-gray-300 hover:bg-gray-700 hover:text-white transition-colors"
    ) do
      plain link[:label]
    end
  end
end
