# frozen_string_literal: true

# The "Edit roles" binding editor — body of the shared `binding-editor` modal,
# rendered inside the `binding-editor` Turbo Frame so add / remove / weight edits
# re-render it in place (the modal stays open). Lists the capability's current
# role bindings (each with a weight field + remove control) and an "add role"
# form offering the roles it isn't bound to yet.
#
# Re-scoping a capability to roles is the editor's primary job (a capability
# bound to no role is hidden from the role-filtered matrix). Weight is editable
# inline; individual tolerance is an advanced lever left to the MCP / API for now.
class Views::Frameworks::Explorer::BindingEditorFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param framework_id [String]
  # @param capability [Frameworks::ExplorerGraph::Capability] graph node (incl. bindings)
  # @param roles_by_id [Hash{String=>FrameworkState::Role}] every role in the framework
  # @param error [String, nil] message to surface from a failed action
  def initialize(framework_id:, capability:, roles_by_id:, error: nil)
    @framework_id = framework_id
    @capability = capability
    @roles_by_id = roles_by_id
    @error = error
  end

  def view_template
    turbo_frame_tag("binding-editor") do
      div(class: "space-y-4") do
        error_banner if @error.present?
        intro
        current_bindings
        add_role_form
      end
    end
  end

  private

  def bindings
    @bindings ||= @capability.bindings.sort_by { |b| role_code(b.role_id) }
  end

  def bound_role_ids
    @bound_role_ids ||= bindings.map(&:role_id).to_set
  end

  def unbound_roles
    @roles_by_id.values.reject { |r| bound_role_ids.include?(r.role_id) }
      .sort_by { |r| r.code.to_s }
  end

  def error_banner
    render Components::Kit::Alert.new(tone: :danger) { @error }
  end

  def intro
    p(class: "text-sm text-muted") do
      plain "Roles that "
      span(class: "font-semibold text-default") { @capability.name }
      plain " applies to. A capability bound to no role is hidden from the role-filtered matrix."
    end
  end

  def current_bindings
    if bindings.empty?
      p(class: "text-sm text-muted italic") { "Not bound to any role yet." }
      return
    end

    ul(class: "divide-y divide-subtle rounded-md border " \
              "border-default") do
      bindings.each { |binding| binding_row(binding) }
    end
  end

  def binding_row(binding)
    li(class: "flex items-center gap-3 px-3 py-2") do
      div(class: "min-w-0 flex-1 flex items-center gap-2") do
        render Components::Kit::Badge.new(role_code(binding.role_id), variant: :default)
        # A binding added in the draft carries the wiggle (the universal
        # "differs from published" signal), not a separate "New in draft" pill.
        span(
          class: "truncate text-sm text-default " \
                 "#{suggestion_text_classes(added_in_draft: binding.added_in_draft)}".strip,
          title: draft_change_title(binding.added_in_draft)
        ) { role_name(binding.role_id) }
      end
      weight_form(binding)
      remove_form(binding)
    end
  end

  # Inline weight editor — PATCH the binding, re-rendering the frame.
  def weight_form(binding)
    form(
      action: framework_capability_binding_path(@framework_id, binding.binding_id),
      method: "post", class: "flex items-center gap-1"
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      label(class: "text-[11px] text-muted") { "Weight" }
      div(class: "w-16") do
        input(
          type: "number", name: "binding[weight]", value: format_weight(binding.weight),
          step: "any", min: "0.1", class: Components::Kit::Field::INLINE
        )
      end
      render Components::Kit::Button.new(variant: :ghost, tone: :brand, size: :xs, type: :submit) { "Save" }
    end
  end

  # Remove (un-scope) the binding — DELETE, re-rendering the frame.
  def remove_form(binding)
    form(
      action: framework_capability_binding_path(@framework_id, binding.binding_id),
      method: "post",
      data: { turbo_confirm: "Remove #{role_code(binding.role_id)} from #{@capability.name}?" }
    ) do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      render Components::Kit::Button.new(variant: :ghost, tone: :danger, size: :xs, type: :submit) { "Remove" }
    end
  end

  def add_role_form
    div(class: "pt-1") do
      if unbound_roles.empty?
        p(class: "text-xs text-muted") { "Bound to every role." }
        return
      end

      form(
        action: framework_capability_bindings_path(@framework_id),
        method: "post", class: "flex items-end gap-2"
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "binding[capability_id]", value: @capability.capability_id)
        role_select
        weight_input
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Add role" }
      end
    end
  end

  def role_select
    div(class: "min-w-0 flex-1") do
      label(for: "binding-add-role",
            class: "block text-[11px] text-muted mb-0.5") { "Add a role" }
      select(
        id: "binding-add-role",
        name: "binding[role_id]",
        class: Components::Kit::Field::SELECT
      ) do
        unbound_roles.each do |role|
          option(value: role.role_id) { "#{role.code} · #{role.name}" }
        end
      end
    end
  end

  def weight_input
    div(class: "w-16 shrink-0") do
      label(class: "block text-[11px] text-muted mb-0.5") { "Weight" }
      input(
        type: "number", name: "binding[weight]", value: "1.0", step: "any", min: "0.1",
        class: Components::Kit::Field::INPUT
      )
    end
  end

  def role_code(role_id)
    @roles_by_id[role_id]&.code || "?"
  end

  def role_name(role_id)
    @roles_by_id[role_id]&.name || "Unknown role"
  end

  # Render a decimal weight without a trailing ".0" so "1.0" shows as "1".
  def format_weight(weight)
    return "1" if weight.nil?

    "%g" % weight.to_f
  end
end
