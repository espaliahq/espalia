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
# Submits to {Frameworks::LevelsController#create}, which answers a Turbo
# Stream carrying the toast and the (now-open) draft status. `add-level-form`
# then dispatches `org-structure:updated` → matrix#refresh: a level adds a
# COLUMN to every row, the one grid change no surgical stream can express.
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
        controller: "add-level-form",
        action: "submit->add-level-form#validate " \
                "turbo:submit-end->add-level-form#submitted " \
                "turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "level[role_id]", data: { add_level_form_target: "roleId" })

      role_context_line
      ordinal_and_code_fields
      ordinal_error_line
      title_field
      is_entry_field
      actions
      draft_note
    end
  end

  # "For <role>" — the trigger-implied parent role.
  def role_context_line
    p(class: "text-sm text-muted") do
      plain "For "
      span(class: "font-medium text-default", data: { add_level_form_target: "roleName" })
    end
  end

  def ordinal_and_code_fields
    div(class: "grid grid-cols-2 gap-3") do
      div do
        label(for: "add-level-ordinal", class: label_classes) { "Level number" }
        input(
          type: "number", id: "add-level-ordinal", name: "level[ordinal]",
          min: "1", required: true, class: Components::Kit::Field::INPUT,
          data: {
            add_level_form_target: "ordinal",
            action: "input->add-level-form#ordinalChanged"
          }
        )
      end
      div do
        label(for: "add-level-code", class: label_classes) { "Code" }
        input(
          type: "text", id: "add-level-code", name: "level[code]", required: true,
          placeholder: "e.g. E4", class: Components::Kit::Field::INPUT,
          data: { add_level_form_target: "code" }
        )
      end
    end
  end

  # Instant duplicate-ordinal feedback — shown/hidden by add-level-form as the
  # user types; the same rule is enforced by the Operation and the aggregate.
  def ordinal_error_line
    p(
      class: "hidden text-sm text-danger",
      data: { add_level_form_target: "ordinalError" },
      aria: { live: "polite" }
    )
  end

  def title_field
    div do
      label(for: "add-level-title", class: label_classes) { "Title" }
      input(
        type: "text", id: "add-level-title", name: "level[title]", required: true,
        placeholder: "e.g. Senior Software Engineer", class: Components::Kit::Field::INPUT,
        data: { add_level_form_target: "title" }
      )
    end
  end

  def is_entry_field
    label(class: "flex items-center gap-2 text-sm text-muted") do
      input(
        type: "checkbox", name: "level[is_entry]", value: "1",
        class: Components::Kit::Field::CHECKBOX,
        data: { add_level_form_target: "isEntry" }
      )
      plain "Entry level for this role"
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      render Components::Kit::Button.new(tone: :brand, type: :submit) { "Add level" }
      render Components::Kit::Button.new(variant: :ghost, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end

  def draft_note
    p(class: "text-xs text-muted") do
      plain "Levels change the rating grid, so this joins the draft and appears "
      plain "in the published framework on the next version."
    end
  end

  def label_classes = "block text-sm font-medium text-default mb-1"
end
