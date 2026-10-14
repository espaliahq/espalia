# frozen_string_literal: true

# Shared resolve-clarification modal for the Framework Explorer (edit mode).
# One instance per page on the explorer root (a pane reload must not destroy
# an open modal — Lesson 19); each pending clarification's "Resolve…" button
# opens it, passing the suggestion id + question preview via the trigger
# dataset (read by the `resolve-clarification-form` Stimulus controller).
#
# The resolution note is REQUIRED — a clarification closes with an answer
# ("reworded L4", "wording is fine; here's the reading"), never silently.
# Submits to {Frameworks::SuggestionsController#resolve} with `inline=1`
# (→ 204; the modal closes, the feed reloads off the activity broadcast,
# the grid refreshes via `suggestion:resolved`).
class Views::Frameworks::Explorer::ResolveClarificationModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "resolve-clarification-modal", title: "Resolve clarification", standalone: false
    ) do |m|
      m.body { resolve_form }
    end
  end

  private

  def resolve_form
    form(
      # __SID__ is substituted with the suggestion id by resolve-clarification-form
      # when the modal opens (the id varies per trigger).
      action: resolve_framework_suggestion_path(@framework_id, "__SID__"),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "resolve-clarification-form",
        resolve_clarification_form_action_template_value:
          resolve_framework_suggestion_path(@framework_id, "__SID__"),
        action: "turbo:submit-end->modal#submitted turbo:submit-end->resolve-clarification-form#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "inline", value: "1")

      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "Declare this question settled — say what answered it."
      end

      p(class: "hidden rounded-md bg-gray-50 dark:bg-gray-800 px-3 py-2 text-sm " \
               "text-gray-700 dark:text-gray-200 line-clamp-3 italic",
        data: { resolve_clarification_form_target: "question" })

      note_field
      actions
    end
  end

  def note_field
    div do
      label(for: "resolve_note",
            class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Resolution" }
      textarea(
        id: "resolve_note", aria: { describedby: "resolve_note-hint" }, name: "note", rows: "2", required: true,
        class: field_classes,
        placeholder: "e.g. Reworded the L4 expectation, or: the wording stands — here's the reading",
        data: { resolve_clarification_form_target: "note" }
      )
      p(id: "resolve_note-hint", class: "mt-1 text-xs text-gray-600 dark:text-gray-300") { Prose::COMPOSER_HINT }
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-primary/80 transition-colors"
      ) { "Resolve clarification" }
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
