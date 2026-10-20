# frozen_string_literal: true

# Form for defining a new assessment cycle.
#
# Only shows frameworks that do NOT already have an open cycle (the partial
# unique index enforces this at the DB level; the controller mirrors that
# filter so the form can't present invalid options).
#
class Views::AssessmentCycles::NewView < Views::Base
  CYCLE_TYPE_LABELS = {
    "regular" => "Regular",
    "performance_review" => "Performance Review",
    "promotion_review" => "Promotion Review"
  }.freeze

  # @param frameworks [Array<FrameworkState::Framework>] frameworks without an open cycle
  # @param cycle_types [Array<String>] allowed cycle_type values
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(frameworks:, cycle_types:, user: nil, current_tenant: nil, tenants: [])
    @frameworks = frameworks
    @cycle_types = cycle_types
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-2xl mx-auto px-4 py-8") do
        back_link
        page_header
        if @frameworks.any?
          cycle_form
        else
          empty_state
        end
      end
    end
  end

  private

  def back_link
    a(
      href: assessment_cycles_path,
      class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 " \
             "dark:hover:text-gray-200 transition-colors"
    ) do
      plain "\u2190 Back to cycles"
    end
  end

  def page_header
    div(class: "mt-4 mb-6") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Define a new cycle" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "A cycle is frozen against the currently-published framework version."
      end
    end
  end

  def cycle_form
    render Components::Kit::Card.new do |card|
      card.body do
        form(action: assessment_cycles_path, method: "post", class: "space-y-6") do
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          framework_field
          name_field
          cycle_type_field
          planned_end_field
          submit_section
        end
      end
    end
  end

  def framework_field
    div do
      label(
        for: "assessment_cycle_framework_id",
        class: "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
      ) { "Framework" }
      select(
        id: "assessment_cycle_framework_id",
        name: "assessment_cycle[framework_id]",
        required: true,
        class: "block w-full rounded-sm border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white"
      ) do
        @frameworks.each do |framework|
          option(value: framework.framework_id) do
            plain "#{framework.name} (v#{framework.current_published_version})"
          end
        end
      end
      p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
        "Only frameworks without an open cycle are listed."
      end
    end
  end

  def name_field
    div do
      label(
        for: "assessment_cycle_name",
        class: "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
      ) { "Name" }
      input(
        type: "text",
        id: "assessment_cycle_name",
        name: "assessment_cycle[name]",
        required: true,
        placeholder: "e.g. Q2 2026 Review",
        class: "block w-full rounded-sm border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white"
      )
    end
  end

  def cycle_type_field
    div do
      label(class: "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2") { "Type" }
      div(class: "space-y-2") do
        @cycle_types.each_with_index do |type, idx|
          div(class: "flex items-center") do
            input(
              type: "radio",
              id: "assessment_cycle_cycle_type_#{type}",
              name: "assessment_cycle[cycle_type]",
              value: type,
              checked: idx.zero?,
              class: "h-4 w-4 text-primary"
            )
            label(
              for: "assessment_cycle_cycle_type_#{type}",
              class: "ml-2 text-sm text-gray-900 dark:text-white"
            ) { CYCLE_TYPE_LABELS.fetch(type, type.humanize) }
          end
        end
      end
    end
  end

  def planned_end_field
    div do
      label(
        for: "assessment_cycle_planned_end_at",
        class: "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
      ) { "Target completion date (optional)" }
      input(
        type: "date",
        id: "assessment_cycle_planned_end_at",
        name: "assessment_cycle[planned_end_at]",
        class: "block w-full rounded-sm border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white"
      )
      p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
        "Soft deadline shown to participants. The cycle remains open until you close it."
      end
    end
  end

  def submit_section
    div(class: "pt-4 border-t border-gray-200 dark:border-gray-700") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-4 py-2 " \
               "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 transition-colors"
      ) { "Define cycle" }
    end
  end

  def empty_state
    div(class: "mt-6 text-center py-12") do
      p(class: "text-gray-600 dark:text-gray-300") do
        "Every framework already has an open cycle. Close one first to define a new one."
      end
    end
  end
end
