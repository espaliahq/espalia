# frozen_string_literal: true

# Shared "add capability" modal for the Framework Explorer (edit mode). One
# instance per page; each category's "+ Add capability" trigger opens it,
# passing the category id/name via the trigger dataset (read by the
# `add-capability-form` Stimulus controller). Captures name, description, and
# which roles the capability applies to (so it's visible in the role-filtered
# matrix), then submits to {Frameworks::CapabilitiesController#create}.
class Views::Frameworks::Explorer::AddCapabilityModal < Views::Base
  # @param framework_id [String]
  # @param roles [Array<Hash>] { id:, label: } binding candidates (all framework roles)
  def initialize(framework_id:, roles: [])
    @framework_id = framework_id
    @roles = roles
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "add-capability-modal", title: "Add capability", standalone: false
    ) do |m|
      m.body { form_body }
    end
  end

  private

  def form_body
    form(
      action: framework_capabilities_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "add-capability-form tree-scope-fields",
        action: "submit->add-capability-form#validateRoles turbo:submit-end->modal#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "capability[category_id]", data: { add_capability_form_target: "categoryId" })

      p(class: "text-sm text-muted") do
        plain "Adding to "
        span(class: "font-semibold text-default",
             data: { add_capability_form_target: "categoryName" }) { "this category" }
        plain "."
      end

      text_field("Name", "capability[name]", "add_capability_name")
      textarea_field("Description", "capability[description]", "add_capability_description")
      roles_field
      actions
    end
  end

  def text_field(label_text, name, id)
    div do
      label(for: id, class: label_classes) { label_text }
      input(type: "text", id: id, name: name, class: Components::Kit::Field::INPUT)
    end
  end

  def textarea_field(label_text, name, id)
    div do
      label(for: id, class: label_classes) { label_text }
      textarea(id: id, name: name, rows: "2", class: Components::Kit::Field::TEXTAREA)
    end
  end

  def roles_field
    div do
      span(class: label_classes) { "Applies to roles" }
      if @roles.empty?
        p(class: "text-xs text-muted") { "No roles defined yet." }
      else
        div(class: "mt-1 grid grid-cols-2 gap-x-4 gap-y-1.5") do
          @roles.each { |role| role_checkbox(role) }
        end
        p(
          class: "hidden mt-1.5 text-xs text-danger",
          data: { add_capability_form_target: "rolesError" }
        ) { "Select at least one role — a capability bound to no role is hidden from the matrix." }
      end
    end
  end

  def role_checkbox(role)
    label(class: "inline-flex items-center gap-1.5 text-sm text-muted") do
      input(type: "checkbox", name: "capability[role_ids][]", value: role[:id],
            data: { add_capability_form_target: "role" },
            class: Components::Kit::Field::CHECKBOX)
      plain role[:label]
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      render Components::Kit::Button.new(tone: :brand, type: :submit) { "Add capability" }
      render Components::Kit::Button.new(variant: :ghost, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end

  def label_classes = "block text-sm font-medium text-default mb-1"
end
