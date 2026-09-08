# frozen_string_literal: true

# Renders one glyph from the page's {Components::Kit::IconSprite} as
# `<svg class="…"><use href="#icon-NAME"/></svg>`.
#
# Usage:
#
#   icon("pencil", class: "w-3 h-3")
#   icon("kebab", class: "w-4 h-4")
#
# Included in Components::Base, so every view and component has it. The sprite
# itself is rendered once per page by {Components::Kit::PageLayout} — a call
# site outside that layout (a bare mailer view, say) must render the sprite
# itself or keep its inline `<svg>`.
module Components::Helpers::IconHelpers
  # @param name [String, Symbol] a key of {Components::Kit::IconSprite::NAMES}
  # @param css [String] classes for the wrapping `<svg>` (size + colour)
  # @return [void]
  def icon(name, class: nil, **attrs)
    css = binding.local_variable_get(:class)
    unless Components::Kit::IconSprite::NAMES.include?(name.to_s)
      raise ArgumentError, "unknown icon #{name.inspect} — add it to Components::Kit::IconSprite"
    end

    svg(class: css, aria: { hidden: "true" }, focusable: "false", **attrs) do |s|
      s.use(href: "#icon-#{name}")
    end
  end
end
