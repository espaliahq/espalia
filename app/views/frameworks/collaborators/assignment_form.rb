# frozen_string_literal: true

# Inline form for adding a framework collaborator assignment.
#
# Used by two surfaces sharing the same primitive:
# 1. Tenant user detail (`/tenant/users/:id`) — person is fixed, framework
#    select drives the scope picker.
# 2. Per-framework collaborators (`/frameworks/:id/settings`) — framework
#    is fixed, person select is shown.
#
# The scope picker is a Turbo Frame fragment (`collaborator-scope-picker`)
# that re-fetches whenever framework or role changes, driven by a small
# Stimulus controller (`collaborator-form`).
#
class Views::Frameworks::Collaborators::AssignmentForm < Components::Base
  FRAMEWORK_WIDE_ROLES = %w[owner editor collaborator viewer].freeze
  SCOPED_ROLES = %w[role_family_lead role_lead capability_category_lead capability_lead].freeze
  ALL_ROLES = (FRAMEWORK_WIDE_ROLES + SCOPED_ROLES).freeze

  # @param form_url [String] action URL for the POST
  # @param scope_picker_url [String] base URL for the scope picker Turbo Frame
  # @param framework [FrameworkState::Framework, nil] when present, framework is locked
  # @param frameworks [Array<FrameworkState::Framework>] options when framework is unlocked
  # @param people [Array<Person>] options when person needs to be selected
  # @param person_locked [Boolean] when true, no person select is rendered
  def initialize(form_url:, scope_picker_url:, framework: nil, frameworks: [],
                 people: [], person_locked: false)
    @form_url = form_url
    @scope_picker_url = scope_picker_url
    @framework = framework
    @frameworks = frameworks
    @people = people
    @person_locked = person_locked
  end

  def view_template
    form(
      action: @form_url,
      method: "post",
      class: "space-y-3",
      data: {
        controller: "collaborator-form",
        collaborator_form_scope_picker_url_value: @scope_picker_url,
        collaborator_form_scoped_roles_value: SCOPED_ROLES.to_json
      }
    ) do
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)

      person_field
      framework_field
      role_field
      scope_picker_slot
      submit_button
    end
  end

  private

  def person_field
    return if @person_locked

    div do
      label_for "Person", :person_id
      select(
        id: "person_id",
        name: "collaborator[person_id]",
        required: true,
        class: select_classes
      ) do
        option(value: "") { "— Pick a person —" }
        @people.each do |person|
          option(value: person.id) { person.name.presence || person.email }
        end
      end
    end
  end

  def framework_field
    if @framework
      input(type: "hidden", name: "collaborator[framework_id]",
            value: @framework.framework_id)
    else
      div do
        label_for "Framework", :framework_id
        select(
          id: "framework_id",
          name: "collaborator[framework_id]",
          required: true,
          class: select_classes,
          data: {
            collaborator_form_target: "frameworkSelect",
            action: "change->collaborator-form#refresh"
          }
        ) do
          option(value: "") { "— Pick a framework —" }
          @frameworks.each do |fw|
            option(value: fw.framework_id) { fw.name }
          end
        end
      end
    end
  end

  def role_field
    div do
      label_for "Role", :role
      select(
        id: "role",
        name: "collaborator[role]",
        required: true,
        class: select_classes,
        data: {
          collaborator_form_target: "roleSelect",
          action: "change->collaborator-form#refresh"
        }
      ) do
        option(value: "") { "— Pick a role —" }
        optgroup(label: "Framework-wide") do
          FRAMEWORK_WIDE_ROLES.each { |r| option(value: r) { r.humanize } }
        end
        optgroup(label: "Scoped") do
          SCOPED_ROLES.each { |r| option(value: r) { r.humanize } }
        end
      end
    end
  end

  def scope_picker_slot
    div(data: { collaborator_form_target: "scopeFrame" }) do
      render Views::Tenant::Users::ScopePickerFrame.new(framework: @framework, role: nil)
    end
  end

  def submit_button
    div(class: "pt-2") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-4 py-2 " \
               "text-sm font-medium text-white hover:bg-primary/90 " \
               "focus:outline-hidden focus:ring-2 focus:ring-primary/50"
      ) { "Add assignment" }
    end
  end

  def label_for(text, field)
    label(for: field,
          class: "block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1") { text }
  end

  def select_classes
    "block w-full rounded-md border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 text-sm text-gray-900 dark:text-gray-100 " \
      "shadow-xs focus:border-primary focus:ring-primary"
  end
end
