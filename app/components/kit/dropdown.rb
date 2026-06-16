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
class Components::Kit::Dropdown < Components::Base
  ALIGNMENT_CLASSES = {
    right: "right-0 origin-top-right",
    left: "left-0 origin-top-left"
  }.freeze

  # @param align [Symbol] Menu alignment relative to trigger (:left or :right)
  def initialize(align: :right)
    @align = align
  end

  def view_template
    div(
      class: "relative inline-block text-left",
      data: {
        controller: "dropdown",
        action: "keydown.esc@window->dropdown#close"
      }
    ) do
      yield(self)
    end
  end

  # Renders the trigger button that toggles the dropdown.
  #
  # @param label [String, nil] accessible name for an icon-only trigger
  #   (sets aria-label so the button isn't nameless to screen readers)
  # @yield The content to display inside the trigger button
  def trigger(label: nil, &block)
    button(
      type: "button",
      aria: { haspopup: "true", expanded: "false", label: label }.compact,
      data: { action: "dropdown#toggle", dropdown_target: "trigger" },
      class: "inline-flex items-center focus:outline-hidden"
    ) do
      yield
    end
  end

  # Renders the dropdown menu panel.
  #
  # @yield The menu content (links, buttons, dividers, etc.)
  def menu(&block)
    div(
      class: "absolute #{ALIGNMENT_CLASSES[@align]} mt-2 w-56 rounded-md shadow-lg " \
             "bg-white dark:bg-gray-800 ring-1 ring-black/5 dark:ring-white/10 " \
             "z-50 hidden",
      data: { dropdown_target: "menu" },
      role: "menu",
      aria: { orientation: "vertical" }
    ) do
      div(class: "py-1", role: "none") do
        yield
      end
    end
  end
end
