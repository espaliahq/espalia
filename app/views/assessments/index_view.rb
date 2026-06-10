# frozen_string_literal: true

# Assessment dashboard listing the current user's framework assignments
# and their direct reports' assessments (manager view).
#
class Views::Assessments::IndexView < Views::Base
  # Per-side completion state → [badge variant, label].
  SIDE_STATES = {
    complete: [ :success, "Complete" ],
    in_progress: [ :warning, "In progress" ],
    not_started: [ :default, "Not started" ]
  }.freeze

  # @param assignments [Array<PersonFrameworkAssignment>] own assignments
  # @param report_assignments [Array<PersonFrameworkAssignment>] direct reports
  # @param report_people [Hash{String => Person}] preloaded person records by ID
  # @param open_cycles [Hash{Array(String, String) => AssessmentCycle}] preloaded open cycles keyed by [framework_id, person_id]
  # @param card_statuses [Hash{Array(String, String) => Hash}] per-card status keyed by [framework_id, person_id]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignments:, report_assignments: [], report_people: {}, open_cycles: {}, card_statuses: {}, user: nil, current_tenant: nil, tenants: [])
    @assignments = assignments
    @report_assignments = report_assignments
    @report_people = report_people
    @open_cycles = open_cycles
    @card_statuses = card_statuses
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
      report_assignments_section if @report_assignments.any?
    end
  end

  private

  def page_header
    div(class: "mb-6") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "My Assessments" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
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

  def report_assignments_section
    div(class: "mt-10") do
      h2(class: "text-xl font-bold text-gray-900 dark:text-white mb-1") { "Team Assessments" }
      p(class: "text-sm text-gray-600 dark:text-gray-300 mb-4") do
        "Review and rate your direct reports\u2019 assessments."
      end
      div(class: "grid gap-4 sm:grid-cols-2 lg:grid-cols-3") do
        @report_assignments.each { |a| report_assignment_card(a) }
      end
    end
  end

  def report_assignment_card(assignment)
    person = @report_people[assignment.person_id]
    cycle = @open_cycles[[ assignment.framework_id, assignment.person_id ]]

    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 p-5 shadow-xs") do
      div(class: "flex items-start justify-between") do
        div do
          h3(class: "text-lg font-semibold text-gray-900 dark:text-white") do
            person&.name || "Team Member"
          end
          p(class: "text-sm text-gray-600 dark:text-gray-300") do
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
        status_badges(assignment, show_manager: true)
      end

      if cycle&.name.present?
        p(class: "mt-3 text-sm text-gray-600 dark:text-gray-300") { cycle.name }
      end

      div(class: "mt-4") do
        a(
          href: assessment_path(assignment),
          class: "inline-flex items-center gap-1.5 rounded-md border border-gray-300 " \
                 "dark:border-gray-600 px-3 py-1.5 text-sm font-medium " \
                 "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 " \
                 "transition-colors"
        ) { "Review Assessment" }
      end
    end
  end

  def assignment_card(assignment)
    cycle = @open_cycles[[ assignment.framework_id, assignment.person_id ]]

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
        status_badges(assignment, show_manager: false)
      end

      if cycle&.name.present?
        p(class: "mt-3 text-sm text-gray-600 dark:text-gray-300") { cycle.name }
      end

      div(class: "mt-4") do
        if cycle
          a(
            href: assessment_path(assignment),
            class: "inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 " \
                   "text-sm font-medium text-white hover:bg-primary/90 transition-colors"
          ) { "Continue Assessment" }
        else
          a(
            href: assessment_path(assignment),
            class: "inline-flex items-center gap-1.5 rounded-md border border-gray-300 " \
                   "dark:border-gray-600 px-3 py-1.5 text-sm font-medium " \
                   "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 " \
                   "transition-colors"
          ) { "View Assessment" }
        end
      end
    end
  end

  # Status block for a card. Reports show both parties (Self + Manager); a
  # person's own card shows self-status only (the manager's progress stays
  # private until alignment). Once alignment starts, a single phase chip
  # replaces the per-side chips.
  #
  # @param assignment [PersonFrameworkAssignment]
  # @param show_manager [Boolean]
  def status_badges(assignment, show_manager:)
    status = @card_statuses[[ assignment.framework_id, assignment.person_id ]]
    return render(Components::Kit::Badge.new("Not Started", variant: :default)) if status.nil?

    case status[:status]
    when "aligning" then return render(Components::Kit::Badge.new("Aligning", variant: :warning))
    when "aligned"  then return render(Components::Kit::Badge.new("Aligned", variant: :success))
    end

    div(class: "flex flex-col items-end gap-1") do
      side_chip("Self", side_state(status[:self_complete], status[:self_any]))
      if show_manager
        side_chip("Manager", side_state(status[:manager_complete], status[:manager_any]))
        if status[:self_complete] && status[:manager_complete]
          span(class: "text-xs text-gray-500 dark:text-gray-400") { "Ready to align" }
        end
      end
    end
  end

  # @return [Symbol] :complete | :in_progress | :not_started
  def side_state(complete, any_rated)
    return :complete if complete
    return :in_progress if any_rated

    :not_started
  end

  # One labelled side chip (e.g. "Self  In progress").
  def side_chip(label, state)
    variant, text = SIDE_STATES.fetch(state)
    div(class: "flex items-center gap-1.5") do
      span(class: "text-xs text-gray-500 dark:text-gray-400") { label }
      render Components::Kit::Badge.new(text, variant: variant)
    end
  end

  def empty_state
    div(class: "rounded-lg border-2 border-dashed border-gray-300 dark:border-gray-600 " \
               "p-12 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "You have not been assigned to any frameworks yet."
      end
    end
  end
end
