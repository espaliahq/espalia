# frozen_string_literal: true

# Reusable dropdown menu component powered by a Stimulus controller
# with `useClickOutside` and `useTransition` from stimulus-use.
#
# Uses a slot pattern: call `trigger` for the clickable element and
# `menu` for the dropdown panel.
#
# @example
#   render Components::Kit::Dropdown.new do |dropdown|
#     dropdown.trigger { "Open menu" }
#     dropdown.menu do
#       dropdown.item(href: "/profile") { "Profile" }
#       dropdown.item(tone: :danger, data: { action: "…" }) { "Delete" }
#     end
#   end
#
# @example A Kit::Button as the trigger
#   render Components::Kit::Dropdown.new do |dropdown|
#     dropdown.trigger(label: "Comment actions",
#                      button: { variant: :ghost, size: :xs, icon: true }) { icon("kebab", class: "size-4") }
#     dropdown.menu { … }
#   end
#
# @example A trigger the site draws itself (the rating pill)
#   button(**mix(dropdown.trigger_attributes, class: "…")) { … }
#
# @example Inside an overflow container (e.g. the role tree's scroll pane)
#   render Components::Kit::Dropdown.new(strategy: :fixed) do |dropdown|
#     ...
#   end
#   # CSS `absolute` positioning clips at the nearest overflow ancestor —
#   # :fixed makes the controller position the open menu against the
#   # viewport instead, so it can escape scroll panes.
class Components::Kit::Dropdown < Components::Base
  ALIGNMENT_CLASSES = {
    right: "right-0 origin-top-right",
    left: "left-0 origin-top-left"
  }.freeze

  # Highlighted and current items take the neutral fills, never brand (#543)
  ITEM_TONES = {
    neutral: "text-default hover:bg-default-hover focus-visible:bg-default-hover",
    danger: "text-danger hover:bg-danger-subtle focus-visible:bg-danger-subtle"
  }.freeze

  ITEM_SIZES = {
    xs: "px-3 py-1.5 text-xs",
    sm: "px-4 py-2 text-sm"
  }.freeze

  # The panel scrolls, which clips an outset ring, so the item's ring sits inside it
  ITEM_BASE = "flex w-full items-center gap-2 text-left cursor-pointer transition-colors " \
              "focus-visible:-outline-offset-2 disabled:cursor-not-allowed disabled:text-disabled"

  # The class string for a menu item, for a site that renders its own (a `button_to`).
  # @param tone [Symbol] :neutral or :danger
  # @param size [Symbol] :xs (compact cards) or :sm
  # @return [String]
  def self.item_classes(tone: :neutral, size: :sm)
    "#{ITEM_BASE} #{ITEM_SIZES.fetch(size)} #{ITEM_TONES.fetch(tone)}"
  end

  # @param align [Symbol] Menu alignment relative to trigger (:left or :right)
  # @param strategy [Symbol] :absolute (default, pure CSS) or :fixed —
  #   viewport-positioned by the controller so the menu escapes
  #   overflow-clipping ancestors
  # @param role [String] the panel's ARIA role. "menu" is ONLY correct when every
  #   child is a menuitem; a panel of prose or forms passes "dialog". The trigger's
  #   aria-haspopup follows it.
  def initialize(align: :right, strategy: :absolute, role: "menu")
    @align = align
    @strategy = strategy
    @role = role
  end

  def view_template
    div(
      class: "relative inline-block text-left",
      data: {
        controller: "dropdown",
        dropdown_fixed_value: (@strategy == :fixed ? "true" : nil),
        dropdown_align_value: (@align.to_s if @strategy == :fixed),
        action: "keydown.esc@window->dropdown#close"
      }.compact
    ) do
      yield(self)
    end
  end

  # What any trigger needs to drive the menu, for a site that draws its own.
  # @return [Hash] `aria:` and `data:` attributes
  def trigger_attributes
    {
      aria: { haspopup: @role, expanded: "false" },
      data: { action: "dropdown#toggle", dropdown_target: "trigger" }
    }
  end

  # Renders the trigger that toggles the dropdown: a bare button, or a
  # {Components::Kit::Button} when `button:` is given.
  #
  # @param label [String, nil] accessible name for an icon-only trigger
  # @param focus_ring [String] the bare trigger's focus ring shape (and colour,
  #   if it must differ from the focus role) — a literal, so Tailwind sees it
  # @param button [Hash, nil] {Components::Kit::Button} options; the Button owns its own focus ring
  # @yield The content to display inside the trigger
  def trigger(label: nil, focus_ring: "rounded-md focus-visible:ring-focus", button: nil, &block)
    attrs = trigger_attributes
    if button
      render Components::Kit::Button.new(
        aria_label: label, **button,
        aria: { **button.fetch(:aria, {}), **attrs[:aria] },
        data: { **button.fetch(:data, {}), **attrs[:data] }
      ), &block
    else
      button(
        type: "button",
        aria: { **attrs[:aria], label: label }.compact,
        data: attrs[:data],
        class: "inline-flex items-center focus:outline-hidden focus-visible:ring-2 #{focus_ring}"
      ) do
        yield
      end
    end
  end

  # Renders the dropdown menu panel.
  #
  # @param width [String] Tailwind width class for the panel (literal —
  #   the JIT can't see interpolation, so callers pass a whole class)
  # @param role [String, nil] overrides the role given to `new`
  # @param label [String, nil] accessible name for non-menu roles
  # @yield The menu content (links, buttons, dividers, etc.)
  def menu(width: "w-56", role: @role, label: nil, &block)
    div(
      # max-h + overflow: a tall panel scrolls its own content instead of
      # overflowing the viewport (fixed-strategy menus close on outside
      # scroll, so without this their lower content was unreachable).
      # The focus ring resets to neutral: in the navbar it follows the nav's text.
      class: "absolute #{ALIGNMENT_CLASSES[@align]} mt-2 #{width} max-h-[70vh] overflow-y-auto " \
             "rounded-md shadow-lg border border-default bg-overlay z-50 hidden " \
             "[--gos-focus-ring:var(--gos-content-default)]",
      data: { dropdown_target: "menu" },
      role: role,
      aria: { orientation: (role == "menu" ? "vertical" : nil), label: label }.compact
    ) do
      div(class: "py-1", role: (role == "menu" ? "none" : nil)) do
        yield
      end
    end
  end

  # One menu item: a link with `href:`, otherwise a button.
  #
  # @param href [String, nil]
  # @param tone [Symbol] :neutral or :danger
  # @param size [Symbol] :xs or :sm
  # @param attrs [Hash] passed through; `class:` is appended
  # @yield the item's content
  def item(href: nil, tone: :neutral, size: :sm, **attrs, &)
    classes = [ self.class.item_classes(tone: tone, size: size), attrs.delete(:class) ].compact.join(" ")
    if href
      a(href: href, role: "menuitem", **attrs, class: classes, &)
    else
      button(type: "button", role: "menuitem", **attrs, class: classes, &)
    end
  end
end
