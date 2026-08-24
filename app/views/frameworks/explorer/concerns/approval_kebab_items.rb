# frozen_string_literal: true

# Shared Approve / Reject kebab machinery for pending suggestions on the grid —
# the matrix-side face of the "actionable feed entry" pattern
# (framework-explorer.md §12). One implementation renders both:
#
# - the Approve / Reject menu items inside an existing kebab (MatrixRow's
#   row-actions dropdown), and
# - a standalone hover-revealed kebab whose menu is only those two items
#   (expectation cells, illustration rows).
#
# Approve is an inline POST via the `suggestion-action` controller
# (`inline=1` → 204 → `suggestion:resolved` → matrix#refresh); Reject opens the
# root-mounted reject-suggestion modal. Callers must only render these for a
# viewer whose precomputed {Frameworks::SuggestionApprovalAuthority} clears the
# suggestion's tier — the authority gate is server-side, never client-side.
module Views::Frameworks::Explorer::Concerns::ApprovalKebabItems
  # Menu-item classes for a kebab dropdown entry — the ONE definition, shared
  # by every kebab menu (matrix and tree; the tree passes its denser padding).
  #
  # @param tone [String] text-colour utilities for the item
  # @param padding [String] item padding — the tree uses "px-3 py-1.5"
  # @return [String]
  def kebab_item_classes(tone = "text-gray-700 dark:text-gray-200", padding: "px-4 py-2")
    "block w-full text-left #{padding} text-sm #{tone} " \
      "hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
  end

  # The hover-revealed ⋮ trigger for a kebab dropdown — one definition of the
  # glyph/hit-target so the grid's kebabs can't drift apart visually.
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
               "w-5 h-5 rounded shrink-0 text-gray-400 hover:text-primary"
      ) do
        svg(class: "w-4 h-4", fill: "currentColor", viewBox: "0 0 20 20") do |s|
          s.path(d: "M10 6a2 2 0 110-4 2 2 0 010 4zm0 2a2 2 0 100 4 2 2 0 000-4zm0 " \
                    "6a2 2 0 100 4 2 2 0 000-4z")
        end
      end
    end
  end

  # The two menu items for one pending suggestion.
  #
  # @param framework_id [String]
  # @param suggestion_id [String]
  # @param change_label [String] reads inline after the verb — "name change"
  # @param entity_label [String] named in the reject modal — "capability name"
  # @param preview [String] the proposed value, shown in the reject modal
  def render_approval_kebab_items(framework_id:, suggestion_id:, change_label:, entity_label:, preview:)
    button(
      type: "button", role: "menuitem",
      class: kebab_item_classes("text-green-700 dark:text-green-400"),
      data: {
        controller: "suggestion-action",
        suggestion_action_approve_url_value:
          approve_framework_suggestion_path(framework_id, suggestion_id, inline: 1),
        # Rides the suggestion:resolved detail so a feed entry showing the
        # same suggestion resolves in place when approved from the grid.
        suggestion_action_suggestion_id_value: suggestion_id,
        action: "suggestion-action#approve"
      }
    ) { "Approve #{change_label}" }

    button(
      type: "button", role: "menuitem",
      class: kebab_item_classes("text-gray-700 dark:text-gray-200"),
      data: {
        action: "click->modal#open",
        modal_target_id: "reject-suggestion-modal",
        reject_suggestion_id: suggestion_id,
        reject_framework_id: framework_id,
        reject_entity_label: entity_label,
        reject_preview: preview
      }
    ) { "Reject #{change_label}" }
  end

  # A standalone hover-revealed ⋮ kebab whose menu is just Approve / Reject.
  #
  # @param framework_id [String]
  # @param suggestion_id [String]
  # @param change_label [String] reads inline after the verb — "expectation change"
  # @param entity_label [String] named in the reject modal — "expectation"
  # @param preview [String] the proposed value, shown in the reject modal
  # @param trigger_label [String] accessible name for the ⋮ trigger
  # @param reveal_classes [String] see {#kebab_trigger}
  # @return [void]
  def render_approval_kebab(framework_id:, suggestion_id:, change_label:, entity_label:,
                            preview:, trigger_label:, reveal_classes:)
    render Components::Kit::Dropdown.new(align: :left) do |dd|
      kebab_trigger(dd, label: trigger_label, reveal_classes: reveal_classes)
      dd.menu do
        render_approval_kebab_items(
          framework_id: framework_id, suggestion_id: suggestion_id,
          change_label: change_label, entity_label: entity_label, preview: preview
        )
      end
    end
  end
end
