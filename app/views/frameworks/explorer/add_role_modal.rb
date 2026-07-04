# frozen_string_literal: true

# Shared "new role" modal for the Framework Explorer (edit mode). One instance
# per page; each family's "+ Add role" row opens it, naming the parent family
# via the trigger dataset — the parent is implied by placement, so there is no
# family picker. The `add-role-form` Stimulus controller sets the hidden
# family id, shows the family name in the context line, and clears the fields
# on open.
#
# Captures the three fields `Operations::Frameworks::AddRole` takes: name,
# short code, and track (IC / Management). Levels are NOT captured here — a
# new role is deliberately created light and renders as a ghost (wiggle) until
# it gains published levels.
#
# Submits to {Frameworks::RolesController#create} targeting the
# `role-tree-families` Turbo Frame, so the role appears under its family in
# place (ghost-wiggled); the current role selection rides along at submit time
# via `tree-scope-fields`. The modal closes on a successful submit.
class Views::Frameworks::Explorer::AddRoleModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "add-role-modal", title: "New role", standalone: false
    ) do |m|
      m.body { form_body }
    end
  end

  private

  def form_body
    form(
      action: framework_roles_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "add-role-form tree-scope-fields",
        turbo_frame: "role-tree-families",
        action: "turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "role[role_family_id]", data: { add_role_form_target: "familyId" })

      family_context_line
      name_field
      code_and_track_fields
      actions
    end
  end

  # "In <family>" — the placement-implied parent, named so the user always
  # knows where the role will land.
  def family_context_line
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      plain "In "
      span(class: "font-medium text-gray-900 dark:text-white", data: { add_role_form_target: "familyName" })
    end
  end

  def name_field
    div do
      label(for: "add-role-name", class: label_classes) { "Name" }
      input(
        type: "text", id: "add-role-name", name: "role[name]", required: true,
        placeholder: "e.g. Engineering Manager", class: field_classes,
        data: { add_role_form_target: "name" }
      )
    end
  end

  def code_and_track_fields
    div(class: "grid grid-cols-2 gap-3") do
      div do
        label(for: "add-role-code", class: label_classes) { "Code" }
        input(
          type: "text", id: "add-role-code", name: "role[code]", required: true,
          placeholder: "e.g. EM", class: field_classes,
          data: { add_role_form_target: "code" }
        )
      end
      div do
        label(for: "add-role-track", class: label_classes) { "Track" }
        select(
          id: "add-role-track", name: "role[track]", class: field_classes,
          data: { add_role_form_target: "track" }
        ) do
          option(value: "ic") { "IC" }
          option(value: "management") { "Management" }
        end
      end
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-primary/90 transition-colors"
      ) { "Add role" }
      button(
        type: "button", data: { action: "click->modal#close" },
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
      ) { "Cancel" }
    end
  end

  def label_classes = "block text-sm font-medium text-gray-900 dark:text-white mb-1"

  def field_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
