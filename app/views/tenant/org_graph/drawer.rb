# frozen_string_literal: true

# The chrome every Org Graph drawer shares: a panel over the right of the
# Units view with a title, a close link and the drawer's own content. The
# unit drawer (5.3) and the person drawer (5.2) each render inside one.
#
# Closing is a link back to the Units view, so the drawer needs no script
# to open or shut; on a phone it takes the whole screen.
class Views::Tenant::OrgGraph::Drawer < Views::Base
  ID = "org-graph-drawer"

  # @param title [String]
  # @param close_href [String] where Close goes, usually the Units view for the same unit
  # @param subtitle [String, nil]
  def initialize(title:, close_href:, subtitle: nil)
    @title = title
    @close_href = close_href
    @subtitle = subtitle
  end

  def view_template(&)
    aside(
      id: ID,
      class: "fixed inset-0 z-30 flex flex-col bg-default lg:inset-y-0 lg:left-auto lg:w-[30rem] " \
             "lg:border-l lg:border-default lg:shadow-lifted",
      aria: { labelledby: "#{ID}-title" }
    ) do
      header(class: "flex items-start gap-3 border-b border-default px-5 py-4") do
        div(class: "min-w-0 flex-1") do
          h2(id: "#{ID}-title", class: "text-lg font-semibold text-default") { @title }
          p(class: "text-sm text-muted") { @subtitle } if @subtitle
        end
        render Components::Kit::Button.new(variant: :ghost, icon: true, href: @close_href, aria_label: "Close") do
          icon(:x, class: "size-5")
        end
      end
      div(class: "flex-1 overflow-y-auto px-5 py-4", &)
    end
  end
end
