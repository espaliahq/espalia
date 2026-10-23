# frozen_string_literal: true

# Mobile-only navigation drawer.
#
# Hidden by default — toggled by the sidebar Stimulus controller's
# hamburger button. On desktop, nav links are in the Navbar instead.
#
# @example
#   render Components::Shell::Sidebar.new(links: [
#     { label: "Home", href: "/" },
#     { label: "Reports", href: "/reports" }
#   ])
class Components::Shell::Sidebar < Components::Base
  DRAWER_ID = "mobile-navigation"

  # @param links [Array<Hash>] Navigation links, each with :label and :href keys
  def initialize(links:)
    @links = links
  end

  def view_template
    aside(
      id: DRAWER_ID,
      class: "hidden fixed inset-y-0 left-0 z-40 w-64 border-r border-default bg-overlay text-default md:hidden",
      data: {
        sidebar_target: "drawer",
        action: "keydown.esc@window->sidebar#escape focusout->sidebar#focusOut"
      }
    ) do
      # The drawer covers the navbar's hamburger, so it carries its own way out in the same spot.
      div(class: "flex items-center h-12 px-4") do
        render Components::Kit::Button.new(variant: :ghost, icon: true, touch: true, aria_label: "Close menu",
                                           class: "-ml-1.5", data: { action: "sidebar#dismiss" }) do
          icon(:x, class: "size-5")
        end
      end
      nav(class: "flex flex-col gap-1 p-4 pt-8 flex-1", aria: { label: "Mobile navigation" }) do
        @links.each { |link| nav_link(link) }
      end
    end
  end

  private

  def nav_link(link)
    a(
      href: link[:href],
      aria: { current: ("page" if link[:current]) },
      class: "flex items-center gap-3 px-3 py-2 min-h-11 rounded-md text-sm font-medium " \
             "text-muted hover:bg-default-hover hover:text-default transition-colors " \
             "aria-[current=page]:bg-neutral-subtle aria-[current=page]:font-semibold aria-[current=page]:text-default"
    ) do
      plain link[:label]
    end
  end
end
