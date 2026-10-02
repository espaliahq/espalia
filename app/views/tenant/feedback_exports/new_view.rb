# frozen_string_literal: true

# Picks the cycle and month for a feedback export (#458) and starts the CSV
# download. Two plain GET forms, no script: choosing a cycle reloads the page
# with that cycle's months, and the download form is a full navigation
# (`data-turbo="false"`) because Turbo cannot hand a file to the browser.
class Views::Tenant::FeedbackExports::NewView < Views::Base
  include Phlex::Rails::Helpers::Routes

  SELECT = "min-h-11 w-full rounded-md border border-gray-300 bg-white px-2 text-sm text-gray-900 " \
           "sm:w-72 dark:border-gray-600 dark:bg-gray-800 dark:text-white"
  LABEL = "text-sm font-medium text-gray-900 dark:text-white"

  # @param cycles [Array<AssessmentCycle>] newest first
  # @param cycle [AssessmentCycle, nil] the cycle being exported
  # @param months [Array<Reporting::CycleMonth>] that cycle's months, newest first
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(cycles:, cycle:, months:, user:, current_tenant:, tenants: [])
    @cycles = cycles
    @cycle = cycle
    @months = months
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::TenantAdminLayout.new(
      active_section: :feedback_export,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Feedback export",
        subtitle: "Download every piece of feedback in a cycle as a CSV file for reporting."
      )

      if @cycle
        div(class: "space-y-6 max-w-3xl") do
          cycle_card
          download_card
        end
      else
        empty_state
      end
    end
  end

  private

  def cycle_card
    render Components::Kit::Card.new(title: "Cycle") do |card|
      card.body do
        form(action: new_tenant_feedback_export_path, method: "get", class: "flex flex-wrap items-end gap-3") do
          div(class: "flex w-full flex-col gap-1 sm:w-auto") do
            label(for: "feedback-export-cycle", class: LABEL) { "Assessment cycle" }
            select(id: "feedback-export-cycle", name: "cycle_id", class: SELECT) do
              @cycles.each do |candidate|
                option(value: candidate.cycle_id, selected: candidate == @cycle) { cycle_label(candidate) }
              end
            end
          end
          button(type: "submit", class: Components::Kit::FrameLoadError::BUTTON_CLASSES) { "Choose cycle" }
        end
      end
    end
  end

  def download_card
    render Components::Kit::Card.new(title: "Download #{@cycle.name}") do |card|
      card.body do
        form(
          id: "feedback-export-download",
          action: tenant_feedback_exports_path(format: :csv), method: "get",
          class: "space-y-4", data: { turbo: "false" }
        ) do
          input(type: "hidden", name: "cycle_id", value: @cycle.cycle_id)
          month_field
          withdrawn_field
          button(
            type: "submit",
            class: "inline-flex min-h-11 items-center rounded-md bg-gray-900 px-4 text-sm font-medium text-white " \
                   "hover:bg-gray-700 dark:bg-white dark:text-gray-900 dark:hover:bg-gray-200"
          ) { "Download CSV" }
        end
        contents_note
      end
    end
  end

  def month_field
    div(class: "flex flex-col gap-1") do
      label(for: "feedback-export-month", class: LABEL) { "Month" }
      select(id: "feedback-export-month", name: "month", class: SELECT) do
        option(value: "") { "Whole cycle" }
        @months.each { |month| option(value: month.key) { month.label } }
      end
      span(class: "text-xs text-gray-600 dark:text-gray-300") { "Feedback recorded in that calendar month (UTC)." }
    end
  end

  def withdrawn_field
    div(class: "flex min-h-11 items-center gap-2") do
      input(
        type: "checkbox", id: "feedback-export-include-withdrawn", name: "include_withdrawn", value: "1",
        class: "h-4 w-4 rounded border-gray-300 text-primary dark:border-gray-600"
      )
      label(for: "feedback-export-include-withdrawn", class: "text-sm text-gray-900 dark:text-white") do
        "Include withdrawn feedback"
      end
    end
  end

  def contents_note
    div(class: "mt-5 space-y-2 border-t border-gray-200 pt-4 text-sm text-gray-600 dark:border-gray-700 " \
               "dark:text-gray-300") do
      p do
        plain "One row per piece of feedback: who gave it, who received it, what it says and the behaviours "
        plain "it applies to. The rows are the feedback the cycle's "
        a(href: evidence_assessment_cycle_path(@cycle), class: "text-primary-ink underline") do
          "feedback & evidence report"
        end
        plain " counts."
      end
      p { "The file holds names, emails and the feedback itself. Keep it where only the people who need it can read it." }
    end
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "No assessment cycles yet. Feedback is exported one cycle at a time."
        end
      end
    end
  end

  def cycle_label(cycle)
    "#{cycle.name} (#{cycle.status})"
  end
end
