# frozen_string_literal: true

# Shared reject-suggestion modal for the Framework Explorer (edit mode). One
# instance per page; each actionable feed entry's "Reject" button opens it,
# passing the suggestion id / entity label / proposed-value preview via the
# trigger dataset (read by the `reject-suggestion-form` Stimulus controller,
# which also points the form at that suggestion's reject endpoint).
#
# Rejecting always routes here (never inline) so a reviewer can add an optional
# reason — surfaced back in the activity feed. Submits to
# {Frameworks::SuggestionsController#reject}, which responds head :ok to the
# Turbo submit; the modal closes, the feed reloads off the activity broadcast,
# and the grid refreshes via the `suggestion:resolved` event.
class Views::Frameworks::Explorer::RejectSuggestionModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "reject-suggestion-modal", title: "Reject suggestion", standalone: false
    ) do |m|
      m.body { reject_form }
    end
  end

  private

  def reject_form
    form(
      # __SID__ is substituted with the suggestion id by reject-suggestion-form
      # when the modal opens (the id varies per trigger).
      action: reject_framework_suggestion_path(@framework_id, "__SID__"),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "reject-suggestion-form",
        reject_suggestion_form_action_template_value: reject_framework_suggestion_path(@framework_id, "__SID__"),
        action: "turbo:submit-end->modal#submitted turbo:submit-end->reject-suggestion-form#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      # Marks this as an inline submit so the controller returns 204 (Turbo
      # closes the modal via submit-end) instead of redirecting to the index.
      input(type: "hidden", name: "inline", value: "1")

      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        plain "Reject the proposed change to "
        span(class: "font-semibold text-gray-900 dark:text-white",
             data: { reject_suggestion_form_target: "title" }) { "this suggestion" }
        plain "."
      end

      p(class: "hidden rounded-md bg-gray-50 dark:bg-gray-800 px-3 py-2 text-sm " \
               "text-gray-700 dark:text-gray-200 line-clamp-3",
        data: { reject_suggestion_form_target: "preview" })

      reason_field
      actions
    end
  end

  def reason_field
    div do
      label(for: "reject_reason",
            class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") do
        plain "Reason "
        span(class: "font-normal text-gray-500 dark:text-gray-400") { "(optional)" }
      end
      textarea(
        id: "reject_reason", name: "comment", rows: "2",
        class: field_classes, placeholder: "Why is this being rejected?",
        data: { reject_suggestion_form_target: "reason" }
      )
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-red-700 transition-colors"
      ) { "Reject suggestion" }
      button(
        type: "button", data: { action: "click->modal#close" },
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
      ) { "Cancel" }
    end
  end

  def field_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
