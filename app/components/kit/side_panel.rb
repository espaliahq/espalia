# frozen_string_literal: true

# A page's main column with a side panel beside it that the viewer can close.
# Closed, the main column takes the full width. The `activity-pane` controller
# remembers the choice in a cookie and the URL; the page reads that cookie to
# render the panel open or closed, so it doesn't flash.
#
# On lg+ the panel sits beside the main column. Below lg it overlays the page
# (`narrow: :overlay`: a tap outside or Escape closes it, and Back does too,
# as for a screen of its own) or stacks under the main column (`narrow: :stack`).
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
# A toggle that sits outside the row, in a page header say, needs the
# controller around both. Give `wrap` the page and place the row in it with
# `columns`; render the toggle there with `SidePanel::Toggle`:
#
#   panel.wrap do
#     header { render Components::Kit::SidePanel::Toggle.new(controls: "…", open:) { "Activity" } }
#     panel.columns
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

  # Keeps the panel in view on lg+ while the page scrolls, under a sticky
  # header if the page sets `--sticky-header-h`, and scrolls its own content.
  STICKY = "overflow-auto overscroll-contain lg:sticky lg:self-start " \
           "lg:top-[calc(var(--sticky-header-h,0px)+1rem)] lg:max-h-[calc(100dvh-var(--sticky-header-h,0px)-2rem)]"

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
  # @param heading [Boolean] false when the body draws its own heading and close button
  # @param sticky [Boolean] keep the panel in view on lg+ as the page scrolls
  # @param fit_viewport [Boolean] cap a sticky panel's height at the room left below its top,
  #   for a page whose header grows, shrinks and scrolls away
  def initialize(id:, title:, open:, cookie:, url_key:, narrow: :overlay, heading: true, sticky: false, fit_viewport: false)
    @id = id
    @title = title
    @open = open
    @cookie = cookie
    @url_key = url_key
    @narrow = NARROW.fetch(narrow)
    @heading = heading
    @sticky = sticky
    @fit_viewport = fit_viewport
  end

  def view_template(&)
    yield(self)
    if @wrap_block
      div(data: controller_data) { @wrap_block.call }
    else
      row(data: controller_data)
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

  # Content around the row, which the controller then covers too. Place the row
  # in it with `columns`.
  #
  # @yield the content, calling `columns` where the row goes
  def wrap(&block)
    @wrap_block = block
  end

  # The main column and the panel, side by side. Call it inside `wrap`.
  def columns = row

  # The button that opens and closes the panel. Call it inside `main`, where it should sit.
  #
  # @param label [String] defaults to the panel's title
  # @yield the label's markup instead, such as a shorter label with the title kept for screen readers
  def toggle(label = @title, &content)
    render Toggle.new(controls: @id, open: @open) { content ? content.call : label }
  end

  private

  def state = @open ? "open" : "closed"

  def controller_data
    { controller: "activity-pane",
      activity_pane_cookie_value: @cookie,
      activity_pane_url_key_value: @url_key,
      activity_pane_default_state_value: state,
      activity_pane_dismiss_outside_value: @narrow[:dismiss_outside].to_s,
      activity_pane_fit_viewport_value: (@fit_viewport.to_s if @fit_viewport),
      activity_pane_screen_value: "true",
      action: "keydown.esc@window->activity-pane#escape:capture" }.compact
  end

  def row(**)
    div(class: "flex flex-col lg:flex-row gap-6", **) do
      div(class: "flex-1 min-w-0") { @main_block&.call }
      panel
    end
  end

  def panel
    aside(id: @id, class: [ PANEL, @narrow[:panel], (STICKY if @sticky), ("hidden" unless @open) ], tabindex: "-1",
          aria: @heading ? { labelledby: "#{@id}-title" } : { label: @title },
          data: { activity_pane_target: "pane", pane_state: state }) do
      if @heading
        div(class: [ "flex items-center justify-between gap-2", @narrow[:header] ]) do
          h2(id: "#{@id}-title", class: "text-base font-semibold text-default") { @title }
          render Close.new(label: "Close #{@title.downcase}") { icon(:x, class: "size-5") }
        end
        div(class: [ "mt-3 space-y-6", @narrow[:body] ]) { @body_block&.call }
      else
        @body_block&.call
      end
    end
  end
end

# The button that opens and closes a side panel, for one that sits outside the
# panel's main column: in a page header, or in a frame that re-renders. It must
# render inside the `SidePanel`, which `wrap` allows.
class Components::Kit::SidePanel::Toggle < Components::Base
  # @param controls [String] the panel's id
  # @param open [Boolean] whether the panel renders open
  # @param button [Hash] Kit::Button options; an outline sm button by default
  def initialize(controls:, open:, **button)
    @controls = controls
    @open = open
    @button = { variant: :outline, size: :sm }.merge(button)
  end

  def view_template(&)
    render Components::Kit::Button.new(
      **@button.except(:data, :aria),
      data: { **@button[:data].to_h, action: "click->activity-pane#toggle", activity_pane_target: "toggle" },
      aria: { **@button[:aria].to_h, expanded: @open.to_s, controls: @controls }, &
    )
  end
end

# The button that closes a side panel, for a body that draws its own heading
# (`SidePanel.new(heading: false)`).
class Components::Kit::SidePanel::Close < Components::Base
  # @param label [String] the button's accessible name
  # @param button [Hash] Kit::Button options; a ghost icon button by default
  def initialize(label:, **button)
    @label = label
    @button = { variant: :ghost, icon: true }.merge(button)
  end

  def view_template(&)
    render Components::Kit::Button.new(**@button.except(:data), aria_label: @label,
                                       data: { **@button[:data].to_h, action: "activity-pane#close" }, &)
  end
end
