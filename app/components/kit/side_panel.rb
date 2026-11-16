# frozen_string_literal: true

# A page's main column with a side panel beside it that the viewer can close.
# Closed, the main column takes the full width. The `activity-pane` controller
# remembers the choice in a cookie and the URL; the page reads that cookie to
# render the panel open or closed, so it doesn't flash.
#
# On lg+ the panel sits beside the main column. Below lg it overlays the page
# (`narrow: :overlay`, and a tap outside closes it) or stacks under the main
# column (`narrow: :stack`).
#
# @example
#   render Components::Kit::SidePanel.new(id: "plan-side-panel", title: "About this plan",
#                                         open: true, cookie: "plan_side_panel_open", url_key: "panel") do |panel|
#     panel.main do
#       panel.toggle
#       render ScenarioTable.new(…)
#     end
#     panel.body { render RulesPanel.new }
#   end
#
class Components::Kit::SidePanel < Components::Base
  NARROW = {
    overlay: {
      panel: "bg-subtle border border-default max-lg:fixed max-lg:inset-y-0 max-lg:right-0 max-lg:z-30 " \
             "max-lg:w-80 max-lg:overflow-y-auto max-lg:shadow-drawer lg:rounded-xl",
      header: "px-4 pt-4",
      body: "px-4 pb-4",
      dismiss_outside: true
    },
    stack: { panel: nil, header: nil, body: nil, dismiss_outside: false }
  }.freeze

  PANEL = "w-full lg:w-80 shrink-0"

  # Whether the panel opens, by the rule the controller applies on connect:
  # the URL's choice, then the cookie's, then the page's default.
  #
  # @param url [String, nil] the query parameter's value
  # @param cookie [String, nil] the cookie's value
  # @param default [Boolean] whether it opens when neither has chosen
  def self.open?(url:, cookie:, default:)
    choice = [ url, cookie ].find { %w[open closed].include?(it) }
    choice ? choice == "open" : default
  end

  # @param id [String] the panel's id, which its toggle controls
  # @param title [String] names the panel, as its heading and its toggle
  # @param open [Boolean] whether it renders open; work it out with `.open?`
  # @param cookie [String] the cookie that remembers the choice, one per surface
  # @param url_key [String] the query parameter that carries it, one per surface
  # @param narrow [Symbol] below lg: :overlay or :stack
  def initialize(id:, title:, open:, cookie:, url_key:, narrow: :overlay)
    @id = id
    @title = title
    @open = open
    @cookie = cookie
    @url_key = url_key
    @narrow = NARROW.fetch(narrow)
  end

  def view_template(&)
    yield(self)
    div(class: "flex flex-col lg:flex-row gap-6",
        data: { controller: "activity-pane",
                activity_pane_cookie_value: @cookie,
                activity_pane_url_key_value: @url_key,
                activity_pane_default_state_value: state,
                activity_pane_dismiss_outside_value: @narrow[:dismiss_outside].to_s }) do
      div(class: "flex-1 min-w-0") { @main_block&.call }
      panel
    end
  end

  # The main column. Call it inside the block.
  #
  # @yield the main column's content
  def main(&block)
    @main_block = block
  end

  # The panel's content. Call it inside the block.
  #
  # @yield the panel's content
  def body(&block)
    @body_block = block
  end

  # The button that opens and closes the panel. Call it inside `main`, where it should sit.
  #
  # @param label [String] defaults to the panel's title
  # @yield the label's markup instead, such as a shorter label with the title kept for screen readers
  def toggle(label = @title, &content)
    render Components::Kit::Button.new(
      variant: :outline, size: :sm,
      data: { action: "activity-pane#toggle", activity_pane_target: "toggle" },
      aria: { expanded: @open.to_s, controls: @id }
    ) { content ? content.call : label }
  end

  private

  def state = @open ? "open" : "closed"

  def panel
    aside(id: @id, class: [ PANEL, @narrow[:panel], ("hidden" unless @open) ],
          aria: { labelledby: "#{@id}-title" },
          data: { activity_pane_target: "pane", pane_state: state }) do
      div(class: [ "flex items-center justify-between gap-2", @narrow[:header] ]) do
        h2(id: "#{@id}-title", class: "text-base font-semibold text-default") { @title }
        render Components::Kit::Button.new(variant: :ghost, icon: true, aria_label: "Close #{@title.downcase}",
                                           data: { action: "activity-pane#close" }) { icon(:x, class: "size-5") }
      end
      div(class: [ "mt-3 space-y-6", @narrow[:body] ]) { @body_block&.call }
    end
  end
end
