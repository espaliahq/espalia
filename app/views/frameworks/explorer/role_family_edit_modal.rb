# frozen_string_literal: true

# Shared role-family modal for the Framework Explorer (edit mode), rendered in
# one of two modes so create and edit can never drift apart:
#
# - `:edit` (default) — the "edit role family" dialog. One instance per page;
#   each family's hover "edit" trigger in the role tree opens it, passing the
#   family's id / name / description / department via the trigger dataset
#   (read by the `role-family-edit-form` Stimulus controller, which also
#   points the form at that family's update endpoint).
# - `:new` — the "new role family" dialog, opened by the tree-foot "+ Add role
#   family" trigger. Same fields, static POST action
#   ({Frameworks::RoleFamiliesController#create} → `Operations::Frameworks::AddRoleFamily`);
#   the controller clears the fields on open.
#
# Both edit all three role-family properties at once (name + description +
# department). Department is a free-text grouping label with a <datalist> of the
# framework's existing departments — typing a new value creates a group, picking
# an existing one moves/places the family into it, clearing it ungroups.
#
# Submits target the `role-tree-families` Turbo Frame, so the family re-groups
# (or the new family appears, ghost-wiggled) in place — the current role
# selection rides along as hidden inputs the Stimulus controller fills from the
# URL. The modal closes on a successful submit (modal#submitted).
class Views::Frameworks::Explorer::RoleFamilyEditModal < Views::Base
  # @param framework_id [String]
  # @param departments [Array<String>] existing department labels for autocomplete
  # @param mode [Symbol] :edit (update an existing family) or :new (create one)
  def initialize(framework_id:, departments: [], mode: :edit)
    @framework_id = framework_id
    @departments = departments
    @mode = mode
  end

  def view_template
    render Components::Kit::Modal.new(
      id: modal_id, title: new_mode? ? "New role family" : "Edit role family", standalone: false
    ) do |m|
      m.body { form_body }
    end
  end

  private

  def new_mode? = @mode == :new

  def modal_id = new_mode? ? "role-family-new-modal" : "role-family-edit-modal"

  # Field ids are prefixed per instance — both modes render on the same page.
  def field_id(name) = "#{modal_id}-#{name}"

  def form_action
    if new_mode?
      framework_role_families_path(@framework_id)
    else
      # __RFID__ is substituted with the role family id by role-family-edit-form
      # when the modal opens (the id varies per trigger).
      framework_role_family_path(@framework_id, "__RFID__")
    end
  end

  def form_body
    form(
      action: form_action,
      method: "post",
      class: "space-y-4",
      data: {
        controller: "role-family-edit-form",
        role_family_edit_form_mode_value: @mode,
        role_family_edit_form_action_template_value: (form_action unless new_mode?),
        turbo_frame: "role-tree-families",
        action: "turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") unless new_mode?
      # Current role selection + track, filled from the browser URL on open so
      # the re-rendered tree keeps the user's selection checked.
      div(class: "hidden", data: { role_family_edit_form_target: "scope" })

      name_field
      description_field
      department_field
      departments_datalist
      actions
    end
  end

  def name_field
    div do
      label(for: field_id("name"), class: label_classes) { "Name" }
      input(
        type: "text", id: field_id("name"), name: "role_family[name]",
        required: true, class: Components::Kit::Field::INPUT, data: { role_family_edit_form_target: "name" }
      )
    end
  end

  def description_field
    div do
      label(for: field_id("description"), class: label_classes) { "Description" }
      textarea(
        id: field_id("description"), name: "role_family[description]", rows: "2",
        class: Components::Kit::Field::TEXTAREA, data: { role_family_edit_form_target: "description" }
      )
    end
  end

  def department_field
    div do
      label(for: field_id("department"), class: label_classes) do
        plain "Department "
        span(class: "font-normal text-muted") { "(grouping)" }
      end
      input(
        type: "text", id: field_id("department"), name: "role_family[department]",
        list: field_id("departments"), autocomplete: "off",
        placeholder: "e.g. Product + Engineering", class: Components::Kit::Field::INPUT,
        data: { role_family_edit_form_target: "department" }
      )
    end
  end

  def departments_datalist
    datalist(id: field_id("departments")) do
      @departments.each { |dept| option(value: dept) }
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      render Components::Kit::Button.new(tone: :brand, type: :submit) { new_mode? ? "Add role family" : "Save" }
      render Components::Kit::Button.new(variant: :ghost, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end

  def label_classes = "block text-sm font-medium text-default mb-1"
end
