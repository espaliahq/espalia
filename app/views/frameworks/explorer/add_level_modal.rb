# frozen_string_literal: true

# Shared "new level" modal for the Framework Explorer (edit mode). One instance
# per page; each role row's hover "+ level" trigger opens it, naming the role
# and its suggested next ordinal via the trigger dataset (read by the
# `add-level-form` Stimulus controller).
#
# Captures the fields `Operations::Frameworks::AddLevel` takes: ordinal
# (prefilled with the role's next free ordinal, editable), title, code, and the
# entry-level flag. Adding a level is **shape-changing** — the aggregate
# auto-opens a draft and the level stays deferred from the published view until
# the next version is published — so the form says so under the submit.
#
# Submits to {Frameworks::LevelsController#create}, which redirects back to the
# edit explorer (selection preserved via `tree-scope-fields`) — a full render
# so the new draft column, the draft pill, and the flash all appear at once.
class Views::Frameworks::Explorer::AddLevelModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "add-level-modal", title: "New level", standalone: false
    ) do |m|
      m.body { form_body }
    end
  end

  private

  def form_body
    form(
      action: framework_levels_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "add-level-form tree-scope-fields",
        action: "turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "level[role_id]", data: { add_level_form_target: "roleId" })

      role_context_line
      ordinal_and_code_fields
      title_field
      is_entry_field
      actions
      draft_note
    end
  end

  # "For <role>" — the trigger-implied parent role.
  def role_context_line
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      plain "For "
      span(class: "font-medium text-gray-900 dark:text-white", data: { add_level_form_target: "roleName" })
    end
  end

  def ordinal_and_code_fields
    div(class: "grid grid-cols-2 gap-3") do
      div do
        label(for: "add-level-ordinal", class: label_classes) { "Level number" }
        input(
          type: "number", id: "add-level-ordinal", name: "level[ordinal]",
          min: "1", required: true, class: field_classes,
          data: { add_level_form_target: "ordinal" }
        )
      end
      div do
        label(for: "add-level-code", class: label_classes) { "Code" }
        input(
          type: "text", id: "add-level-code", name: "level[code]", required: true,
          placeholder: "e.g. E4", class: field_classes,
          data: { add_level_form_target: "code" }
        )
      end
    end
  end

  def title_field
    div do
      label(for: "add-level-title", class: label_classes) { "Title" }
      input(
        type: "text", id: "add-level-title", name: "level[title]", required: true,
        placeholder: "e.g. Senior Software Engineer", class: field_classes,
        data: { add_level_form_target: "title" }
      )
    end
  end

  def is_entry_field
    label(class: "flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300") do
      input(
        type: "checkbox", name: "level[is_entry]", value: "1",
        class: "rounded-xs border-gray-300 dark:border-gray-600 text-primary focus:ring-primary",
        data: { add_level_form_target: "isEntry" }
      )
      plain "Entry level for this role"
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-primary/90 transition-colors"
      ) { "Add level" }
      button(
        type: "button", data: { action: "click->modal#close" },
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
      ) { "Cancel" }
    end
  end

  def draft_note
    p(class: "text-xs text-gray-500 dark:text-gray-400") do
      plain "Levels change the rating grid, so this joins the draft and appears "
      plain "in the published framework on the next version."
    end
  end

  def label_classes = "block text-sm font-medium text-gray-900 dark:text-white mb-1"

  def field_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
