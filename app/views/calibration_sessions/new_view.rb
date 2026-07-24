# frozen_string_literal: true

# Define a calibration session: name, cycle, and the participating
# raters. The population is auto-seeded from the participants' reports
# on create, then curated on the session's draft page.
class Views::CalibrationSessions::NewView < Views::Base
  # @param open_cycles [Array<AssessmentCycle>]
  # @param participant_candidates [Array<Person>] managers the caller may pick
  def initialize(open_cycles:, participant_candidates:,
                 user: nil, current_tenant: nil, tenants: [])
    @open_cycles = open_cycles
    @participant_candidates = participant_candidates
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-2xl mx-auto px-4 py-8") do
        render Components::Kit::SectionHeading.new(
          "Define calibration session",
          subtitle: "Pick the raters to calibrate with each other — their reports seed the population"
        )

        if @open_cycles.empty?
          empty_state
        else
          session_form
        end
      end
    end
  end

  private

  def session_form
    form(action: calibration_sessions_path, method: "post", class: "mt-6 space-y-6") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      field_wrapper do
        label(for: "session-name", class: label_classes) { "Session name" }
        input(
          id: "session-name", type: "text", name: "calibration_session[name]",
          required: true, placeholder: "e.g. Engineering calibration",
          class: input_classes
        )
      end

      field_wrapper do
        label(for: "session-cycle", class: label_classes) { "Assessment cycle" }
        select(id: "session-cycle", name: "calibration_session[cycle_id]", required: true, class: input_classes) do
          @open_cycles.each do |cycle|
            option(value: cycle.cycle_id) { cycle.name }
          end
        end
      end

      fieldset do
        legend(class: label_classes) { "Participants (raters)" }
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
          plain "Participants calibrate each other's ratings. They are excluded from the " \
                "population — their own calibration happens in a separate session."
        end
        div(class: "mt-3 space-y-2") do
          if @participant_candidates.empty?
            p(class: "text-sm text-gray-600 dark:text-gray-300") { "No managers found in your org." }
          else
            @participant_candidates.each { |person| participant_checkbox(person) }
          end
        end
      end

      div(class: "flex items-center gap-3") do
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm " \
                 "font-semibold text-white shadow-xs hover:bg-primary/90 " \
                 "focus-visible:outline focus-visible:outline-2 " \
                 "focus-visible:outline-offset-2 focus-visible:outline-primary"
        ) { "Create draft session" }
        a(href: calibration_sessions_path, class: "text-sm text-gray-600 dark:text-gray-300 hover:underline min-h-11 inline-flex items-center") { "Cancel" }
      end
    end
  end

  def participant_checkbox(person)
    label(class: "flex items-center gap-3 rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2 min-h-11 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800") do
      input(
        type: "checkbox", name: "calibration_session[participant_ids][]",
        value: person.id, class: "h-4 w-4 rounded-sm border-gray-300"
      )
      span(class: "text-sm text-gray-900 dark:text-white") { person.name }
      if person.job_title.present?
        span(class: "text-xs text-gray-600 dark:text-gray-300") { person.job_title }
      end
    end
  end

  def empty_state
    div(class: "mt-6 text-center py-12") do
      p(class: "text-gray-600 dark:text-gray-300") do
        plain "Calibration sessions run within an open assessment cycle — there are none right now."
      end
    end
  end

  def field_wrapper(&block)
    div(&block)
  end

  def label_classes
    "block text-sm font-medium text-gray-900 dark:text-white"
  end

  def input_classes
    "mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-white"
  end
end
