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
    div(class: "rounded-md bg-red-50 dark:bg-red-900/20 border border-red-200 " \
               "dark:border-red-800 px-3 py-2 text-sm text-red-700 dark:text-red-300") { @error }
  end

  def intro
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      plain "Roles that "
      span(class: "font-semibold text-gray-900 dark:text-white") { @capability.name }
      plain " applies to. A capability bound to no role is hidden from the role-filtered matrix."
    end
  end

  def current_bindings
    if bindings.empty?
      p(class: "text-sm text-gray-500 dark:text-gray-400 italic") { "Not bound to any role yet." }
      return
    end

    ul(class: "divide-y divide-gray-100 dark:divide-gray-800 rounded-md border " \
              "border-gray-200 dark:border-gray-700") do
      bindings.each { |binding| binding_row(binding) }
    end
  end

  def binding_row(binding)
    li(class: "flex items-center gap-3 px-3 py-2") do
      div(class: "min-w-0 flex-1 flex items-center gap-2") do
        render Components::Kit::Badge.new(role_code(binding.role_id), variant: :default)
        span(class: "truncate text-sm text-gray-900 dark:text-gray-100") { role_name(binding.role_id) }
        draft_chip if binding.added_in_draft
      end
      weight_form(binding)
      remove_form(binding)
    end
  end

  def draft_chip
    span(class: "inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold " \
                "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300") { "New in draft" }
  end

  # Inline weight editor — PATCH the binding, re-rendering the frame.
  def weight_form(binding)
    form(
      action: framework_capability_binding_path(@framework_id, binding.binding_id),
      method: "post", class: "flex items-center gap-1"
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      label(class: "text-[11px] text-gray-500 dark:text-gray-400") { "Weight" }
      input(
        type: "number", name: "binding[weight]", value: format_weight(binding.weight),
        step: "any", min: "0.1",
        class: "w-16 rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 " \
               "px-2 py-1 text-sm text-gray-900 dark:text-white " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
      )
      button(
        type: "submit",
        class: "rounded px-2 py-1 text-[11px] font-medium text-primary hover:bg-primary/10 transition-colors"
      ) { "Save" }
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
      button(
        type: "submit",
        class: "rounded px-2 py-1 text-[11px] font-medium text-red-600 dark:text-red-400 " \
               "hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
      ) { "Remove" }
    end
  end

  def add_role_form
    div(class: "pt-1") do
      if unbound_roles.empty?
        p(class: "text-xs text-gray-500 dark:text-gray-400") { "Bound to every role." }
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
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-primary px-3 py-1.5 text-sm font-semibold " \
                 "text-white hover:bg-primary/90 transition-colors shrink-0"
        ) { "Add role" }
      end
    end
  end

  def role_select
    div(class: "min-w-0 flex-1") do
      label(for: "binding-add-role",
            class: "block text-[11px] text-gray-500 dark:text-gray-400 mb-0.5") { "Add a role" }
      select(
        id: "binding-add-role",
        name: "binding[role_id]",
        class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-1.5 text-sm text-gray-900 dark:text-white " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
      ) do
        unbound_roles.each do |role|
          option(value: role.role_id) { "#{role.code} · #{role.name}" }
        end
      end
    end
  end

  def weight_input
    div(class: "shrink-0") do
      label(class: "block text-[11px] text-gray-500 dark:text-gray-400 mb-0.5") { "Weight" }
      input(
        type: "number", name: "binding[weight]", value: "1.0", step: "any", min: "0.1",
        class: "w-16 rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 " \
               "px-2 py-1.5 text-sm text-gray-900 dark:text-white " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
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
