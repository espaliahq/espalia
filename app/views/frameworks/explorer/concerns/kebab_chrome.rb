# frozen_string_literal: true

# Shared chrome for the explorer's remaining `Kit::Dropdown` kebabs — today
# just the role tree's per-role ⋮ menu.
#
# The matrix grid's kebabs are NOT built this way any more: they ship as a bare
# trigger plus a JSON item list and are built on open by
# `explorer_menu_controller.js` (see
# {Views::Frameworks::Explorer::Concerns::MenuItems}). The tree keeps
# `Kit::Dropdown` because it is one menu per role in a pane the user scrolls —
# not the thousands the grid was rendering — and it needs the component's
# `strategy: :fixed` to escape that pane's overflow.
module Views::Frameworks::Explorer::Concerns::KebabChrome
  # Menu-item classes for a kebab dropdown entry.
  #
  # @param tone [String] text-colour utilities for the item
  # @param padding [String] item padding — the tree uses "px-3 py-1.5"
  # @return [String]
  def kebab_item_classes(tone = "text-muted", padding: "px-4 py-2")
    "block w-full text-left #{padding} text-sm #{tone} " \
      "hover:bg-default-hover transition-colors cursor-pointer"
  end

  # The hover-revealed ⋮ trigger for a `Kit::Dropdown`.
  #
  # @param dd [Components::Kit::Dropdown] the dropdown being configured
  # @param label [String] accessible name for the trigger
  # @param reveal_classes [String] hover/focus reveal utilities — passed as a
  #   literal at each call site so Tailwind's scanner sees them (group tokens
  #   can't be interpolated; Hard-Won Lesson 12)
  # @return [void]
  def kebab_trigger(dd, label:, reveal_classes:)
    dd.trigger(label: label) do
      # pointer-coarse keeps the trigger permanently visible on touch devices,
      # where hover-reveal would leave it undiscoverable.
      span(
        class: "#{reveal_classes} pointer-coarse:opacity-100 transition-opacity " \
               "inline-flex items-center justify-center " \
               "w-5 h-5 rounded shrink-0 text-subtle hover:text-brand"
      ) do
        # Sized here, not by a parent rule: this trigger is a `Kit::Dropdown`
        # span, not one of the grid's `.explorer-kebab` buttons (whose glyph the
        # button sizes — #383). One per role in the tree, so the utility costs
        # nothing worth saving.
        icon("kebab", class: "w-4 h-4")
      end
    end
  end
end
