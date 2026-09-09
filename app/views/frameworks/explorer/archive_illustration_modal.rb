# frozen_string_literal: true

# Shared archive-illustration modal for the Framework Explorer (edit mode). One
# instance per page on the explorer root; each illustration's ⋮ "Archive…" item
# opens it, passing the illustration's id and an excerpt of its text via the
# trigger dataset (read by the `archive-illustration-form` Stimulus controller).
#
# Replaces the native `window.confirm()` the menu's inline form used to fire.
# Three reasons the browser dialog had to go: it can't be themed or focus-
# managed, it left the archive as the last edit-mode write with no place to
# capture a reason, and `data-turbo-confirm` is the single most flake-prone
# construct in the system suite (testing.md — `auto_confirm`). Root-mounted
# like every other explorer modal so an expanded-row re-render can't destroy
# the open dialog (Hard-Won Lesson 19).
#
# Submits to {Frameworks::IllustrationArchivesController#create}, which — like
# the capability archive — lets the Operation decide from the edit/suggest
# toggle plus the viewer's authority whether the removal applies directly or
# lands as a pending suggestion.
class Views::Frameworks::Explorer::ArchiveIllustrationModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "archive-illustration-modal", title: "Archive example", standalone: false
    ) do |m|
      m.body { archive_form }
    end
  end

  private

  def archive_form
    form(
      action: framework_illustration_archives_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "archive-illustration-form tree-scope-fields",
        action: "turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "archive[illustration_id]",
            data: { archive_illustration_form_target: "illustrationId" })

      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        plain "Archiving "
        span(class: "font-semibold text-gray-900 dark:text-white",
             data: { archive_illustration_form_target: "title" }) { "this example" }
        plain "."
      end

      reason_field
      actions
    end
  end

  def reason_field
    div do
      label(for: "archive_illustration_reason",
            class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Reason" }
      textarea(
        id: "archive_illustration_reason", name: "archive[reason]", rows: "2",
        class: field_classes, placeholder: "Why is this example being removed?",
        data: { archive_illustration_form_target: "reason" }
      )
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-red-700 transition-colors"
      ) { "Archive example" }
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
