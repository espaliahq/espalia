# frozen_string_literal: true

# The §12 inline-resolution affordance pair — one-click Approve (via the
# suggestion-action controller, `inline=1` → 204) and Reject via the
# root-mounted reject modal. Shared by every surface that lets a reviewer
# act on a pending suggestion (feed entry, pane suggestion card) so the
# endpoint wiring, the reject-modal dataset contract, and the styling
# can't drift between hand-copied sites.
#
class Views::Frameworks::Activity::SuggestionActions < Views::Base
  # @param framework_id [String]
  # @param suggestion_id [String]
  # @param entity_label [String] user-facing entity word for the reject modal
  # @param reject_preview [String, nil] the proposed value shown in the modal
  def initialize(framework_id:, suggestion_id:, entity_label:, reject_preview: nil)
    @framework_id = framework_id
    @suggestion_id = suggestion_id
    @entity_label = entity_label
    @reject_preview = reject_preview
  end

  def view_template
    div(
      class: "mt-1.5",
      data: {
        controller: "suggestion-action",
        suggestion_action_approve_url_value:
          approve_framework_suggestion_path(@framework_id, @suggestion_id, inline: 1),
        suggestion_action_suggestion_id_value: @suggestion_id,
        # A resolution landed elsewhere (the reject modal, another surface for
        # the same suggestion) — swap this row to its resolved state too.
        action: "suggestion:resolved@window->suggestion-action#onResolved"
      }
    ) do
      div(class: "flex items-center gap-2", data: { suggestion_action_target: "actions" }) do
        approve_button
        reject_button
      end
      # Instant local feedback: shown the moment the approve POST (or the
      # reject modal) succeeds, ~1-2s before the broadcast-driven feed reload
      # renders the canonical resolution entry. Text set by the controller
      # ("✓ Approved" / "✓ Rejected").
      p(
        class: "hidden text-[11px] font-medium text-green-700 dark:text-green-400",
        data: { suggestion_action_target: "resolved" }
      )
    end
  end

  private

  def approve_button
    button(
      type: "button",
      class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
             "bg-green-600 text-white hover:bg-green-700 transition-colors " \
             "disabled:opacity-50 disabled:cursor-not-allowed",
      data: { action: "suggestion-action#approve" }
    ) { "Approve" }
  end

  def reject_button
    button(
      type: "button",
      class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
             "border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors",
      data: {
        action: "click->modal#open",
        modal_target_id: "reject-suggestion-modal",
        reject_suggestion_id: @suggestion_id,
        reject_framework_id: @framework_id,
        reject_entity_label: @entity_label,
        reject_preview: @reject_preview
      }
    ) { "Reject" }
  end
end
