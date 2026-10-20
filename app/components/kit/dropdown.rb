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
#       a(href: "/profile") { "Profile" }
#       a(href: "/settings") { "Settings" }
#     end
#   end
#
# @example Right-aligned (default)
#   render Components::Kit::Dropdown.new(align: :right) do |dropdown|
#     dropdown.trigger { "Menu" }
#     dropdown.menu { "Content" }
#   end
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

  # @param align [Symbol] Menu alignment relative to trigger (:left or :right)
  # @param strategy [Symbol] :absolute (default, pure CSS) or :fixed —
  #   viewport-positioned by the controller so the menu escapes
  #   overflow-clipping ancestors
  def initialize(align: :right, strategy: :absolute)
    @align = align
    @strategy = strategy
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

  # Renders the trigger button that toggles the dropdown.
  #
  # @param label [String, nil] accessible name for an icon-only trigger
  #   (sets aria-label so the button isn't nameless to screen readers)
  # @param focus_ring [String] the keyboard focus ring's shape (and colour,
  #   if it must differ from the focus role) — a literal, so Tailwind sees it
  # @yield The content to display inside the trigger button
  def trigger(label: nil, focus_ring: "rounded-md focus-visible:ring-focus", &block)
    button(
      type: "button",
      aria: { haspopup: "true", expanded: "false", label: label }.compact,
      data: { action: "dropdown#toggle", dropdown_target: "trigger" },
      class: "inline-flex items-center focus:outline-hidden focus-visible:ring-2 #{focus_ring}"
    ) do
      yield
    end
  end

  # Renders the dropdown menu panel.
  #
  # @param width [String] Tailwind width class for the panel (literal —
  #   the JIT can't see interpolation, so callers pass a whole class)
  # @param role [String, nil] ARIA role. "menu" (default) is ONLY correct
  #   when every child is a menuitem; a panel of prose/forms (the level
  #   ⓘ) passes "dialog" + a label so AT doesn't apply menu semantics to
  #   content that has none.
  # @param label [String, nil] accessible name for non-menu roles
  # @yield The menu content (links, buttons, dividers, etc.)
  def menu(width: "w-56", role: "menu", label: nil, &block)
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
end
