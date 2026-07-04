# frozen_string_literal: true

# Shared role modal for the Framework Explorer (edit mode), rendered in one of
# two modes so create and edit can never drift apart (the RoleFamilyEditModal
# pattern):
#
# - `:new` (default) — the "new role" dialog. Each family's "+ Add role" row
#   opens it, naming the parent family via the trigger dataset — the parent is
#   implied by placement, so there is no family picker. POSTs to
#   {Frameworks::RolesController#create}; the `role-tree-families` frame
#   re-renders with the role ghost-wiggled.
# - `:edit` — the "edit role" dialog (name + code + track), opened from the
#   role row's kebab. Code/track are deliberately dialog-only, not inline
#   pencils: track is an enum and a code edit ripples through every matrix
#   header badge. PATCHes to {Frameworks::RolesController#update} (action
#   template, id substituted on open) targeting the same tree frame; the
#   `add-role-form` controller also fires `org-structure:updated` on success
#   so the acting user's matrix re-fetches and the header badges update.
#
# Both capture the fields `Operations::Frameworks::{AddRole,UpdateRole}` take:
# name, short code, and track (IC / Management). Levels are managed separately
# (the "+ level" modal and the levels editor).
class Views::Frameworks::Explorer::AddRoleModal < Views::Base
  # @param framework_id [String]
  # @param mode [Symbol] :new (create a role) or :edit (update one)
  def initialize(framework_id:, mode: :new)
    @framework_id = framework_id
    @mode = mode
  end

  def view_template
    render Components::Kit::Modal.new(
      id: modal_id, title: edit_mode? ? "Edit role" : "New role", standalone: false
    ) do |m|
      m.body { form_body }
    end
  end

  private

  def edit_mode? = @mode == :edit

  def modal_id = edit_mode? ? "role-edit-modal" : "add-role-modal"

  # Field ids are prefixed per instance — both modes render on the same page.
  def field_id(name) = "#{modal_id}-#{name}"

  def form_action
    if edit_mode?
      # __RID__ is substituted with the role id by add-role-form on open.
      framework_role_path(@framework_id, "__RID__")
    else
      framework_roles_path(@framework_id)
    end
  end

  def form_body
    form(
      action: form_action,
      method: "post",
      class: "space-y-4",
      data: {
        controller: "add-role-form tree-scope-fields",
        add_role_form_mode_value: @mode,
        add_role_form_action_template_value: (form_action if edit_mode?),
        turbo_frame: "role-tree-families",
        action: "turbo:submit-end->add-role-form#submitted turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if edit_mode?
      unless edit_mode?
        input(type: "hidden", name: "role[role_family_id]", data: { add_role_form_target: "familyId" })
      end

      family_context_line unless edit_mode?
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
      label(for: field_id("name"), class: label_classes) { "Name" }
      input(
        type: "text", id: field_id("name"), name: "role[name]", required: true,
        placeholder: "e.g. Engineering Manager", class: field_classes,
        data: { add_role_form_target: "name" }
      )
    end
  end

  def code_and_track_fields
    div(class: "grid grid-cols-2 gap-3") do
      div do
        label(for: field_id("code"), class: label_classes) { "Code" }
        input(
          type: "text", id: field_id("code"), name: "role[code]", required: true,
          placeholder: "e.g. EM", class: field_classes,
          data: { add_role_form_target: "code" }
        )
      end
      div do
        label(for: field_id("track"), class: label_classes) { "Track" }
        select(
          id: field_id("track"), name: "role[track]", class: field_classes,
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
      ) { edit_mode? ? "Save" : "Add role" }
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
