# frozen_string_literal: true

# Define a calibration session: name, cycle, and the participating
# raters (picked via the shared person picker — managers only, scoped to
# the caller's subtree, or org-wide for admins). The population is
# auto-seeded from the participants' reports on create, then curated on
# the session's draft page.
class Views::CalibrationSessions::NewView < Views::Base
  # @param open_cycles [Array<AssessmentCycle>]
  # @param participant_suggestions [Array<Hash>] quick-add entries ({ person:, subtitle: })
  def initialize(open_cycles:, participant_suggestions:,
                 user: nil, current_tenant: nil, tenants: [])
    @open_cycles = open_cycles
    @participant_suggestions = participant_suggestions
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
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
          class: "mt-1 #{Components::Kit::Field::INPUT}"
        )
      end

      field_wrapper do
        label(for: "session-cycle", class: label_classes) { "Assessment cycle" }
        select(id: "session-cycle", name: "calibration_session[cycle_id]", required: true,
                 class: "mt-1 #{Components::Kit::Field::SELECT}") do
          @open_cycles.each do |cycle|
            option(value: cycle.cycle_id) { cycle.name }
          end
        end
      end

      render Views::Shared::PersonPicker.new(
        field_name: "calibration_session[participant_ids][]",
        candidates_url: participant_candidates_calibration_sessions_path,
        frame_id: "participant-candidates",
        label: "Participants (raters)",
        placeholder: "Search managers by name or email…",
        hint: "Participants calibrate each other's ratings. They are excluded from the " \
              "population — their own calibration happens in a separate session.",
        suggestions: @participant_suggestions,
        empty_text: "No raters selected yet."
      )

      div(class: "flex items-center gap-3") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Create draft session" }
        a(href: calibration_sessions_path, class: "text-sm text-muted hover:underline min-h-11 inline-flex items-center") { "Cancel" }
      end
    end
  end

  def empty_state
    div(class: "mt-6") do
      render Components::Kit::EmptyState.new(title: "No open assessment cycles") do
        "Calibration sessions run within an open assessment cycle — there are none right now."
      end
    end
  end

  def field_wrapper(&block)
    div(&block)
  end

  def label_classes
    "block text-sm font-medium text-default"
  end
end
