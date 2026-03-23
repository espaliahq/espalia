# frozen_string_literal: true

# Assessment dashboard listing the current user's framework assignments.
#
class Views::Assessments::IndexView < Views::Base
  # @param assignments [Array<PersonFrameworkAssignment>]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignments:, user: nil, current_tenant: nil, tenants: [])
    @assignments = assignments
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      page_header
      assignments_list
    end
  end

  private

  def page_header
    div(class: "mb-6") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "My Assessments" }
      p(class: "mt-1 text-sm text-gray-500 dark:text-gray-400") do
        "Self-assess your capabilities against your assigned framework."
      end
    end
  end

  def assignments_list
    if @assignments.empty?
      empty_state
    else
      div(class: "grid gap-4 sm:grid-cols-2 lg:grid-cols-3") do
        @assignments.each { |a| assignment_card(a) }
      end
    end
  end

  def assignment_card(assignment)
    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 p-5 shadow-xs") do
      div(class: "flex items-start justify-between") do
        div do
          h3(class: "text-lg font-semibold text-gray-900 dark:text-white") do
            assignment.framework&.name || "Framework"
          end
          div(class: "mt-1 flex items-center gap-2") do
            if assignment.role
              render Components::Kit::Badge.new(assignment.role.name, variant: :info)
            end
            if assignment.level
              render Components::Kit::Badge.new(assignment.level.title, variant: :default)
            end
          end
        end
        cycle_status_badge(assignment)
      end

      if assignment.cycle_name.present?
        p(class: "mt-3 text-sm text-gray-500 dark:text-gray-400") { assignment.cycle_name }
      end

      div(class: "mt-4") do
        if assignment.cycle_open?
          a(
            href: assessment_path(assignment.framework_id),
            class: "inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 " \
                   "text-sm font-medium text-white hover:bg-primary/90 transition-colors"
          ) { "Continue Assessment" }
        else
          a(
            href: assessment_path(assignment.framework_id),
            class: "inline-flex items-center gap-1.5 rounded-md border border-gray-300 " \
                   "dark:border-gray-600 px-3 py-1.5 text-sm font-medium " \
                   "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 " \
                   "transition-colors"
          ) { "View Assessment" }
        end
      end
    end
  end

  def cycle_status_badge(assignment)
    case assignment.cycle_status
    when "open"
      render Components::Kit::Badge.new("In Progress", variant: :warning)
    when "completed"
      render Components::Kit::Badge.new("Completed", variant: :success)
    else
      render Components::Kit::Badge.new("Not Started", variant: :default)
    end
  end

  def empty_state
    div(class: "rounded-lg border-2 border-dashed border-gray-300 dark:border-gray-600 " \
               "p-12 text-center") do
      p(class: "text-sm text-gray-500 dark:text-gray-400") do
        "You have not been assigned to any frameworks yet."
      end
    end
  end
end
