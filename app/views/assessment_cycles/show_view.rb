# frozen_string_literal: true

# Detail page for a single assessment cycle.
#
# Shows cycle metadata, participant list, enroll / unenroll affordances
# (for admins, when the cycle is open), and a close-cycle action.
#
class Views::AssessmentCycles::ShowView < Views::Base
  STATUS_VARIANTS = {
    "enrolled" => :default,
    "started" => :info,
    "self_complete" => :info,
    "manager_complete" => :info,
    "aligned" => :success,
    "withdrawn" => :warning
  }.freeze

  # @param cycle [AssessmentCycle]
  # @param framework [FrameworkState::Framework, nil]
  # @param eligible_people [Array<Person>] people who can be enrolled (admin only)
  # @param is_admin [Boolean] whether the viewer can enroll/unenroll/close
  # @param can_view_cohort [Boolean] whether to render the cohort progress link
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(cycle:, framework:, eligible_people:, is_admin:,
                 can_view_cohort: false, user: nil, current_tenant: nil, tenants: [])
    @cycle = cycle
    @framework = framework
    @eligible_people = eligible_people
    @is_admin = is_admin
    @can_view_cohort = can_view_cohort
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-5xl mx-auto px-4 py-8") do
        back_link
        header
        metadata_card
        participants_card
        enroll_card if @is_admin && @cycle.open?
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

  def header
    div(class: "mt-4 mb-8 flex items-start justify-between gap-4") do
      div do
        render Views::AssessmentCycles::CycleNameFrame.new(cycle: @cycle, is_admin: @is_admin)
      end
      div(class: "flex items-center gap-3") do
        attainment_link if @can_view_cohort
        cohort_link if @can_view_cohort
        render Components::Kit::Badge.new(
          @cycle.open? ? "Open" : "Closed",
          variant: @cycle.open? ? :success : :default
        )
        close_button if @is_admin && @cycle.open?
      end
    end
  end

  # Link to the cohort progress roll-up. Shown only to viewers who can open it
  # (admins, or managers with participants in their subtree) — see
  # AssessmentCyclePolicy#cohort?.
  def cohort_link
    a(
      href: cohort_assessment_cycle_path(@cycle),
      class: "inline-flex items-center rounded-md bg-gray-100 px-3 py-1.5 text-sm font-semibold " \
             "text-gray-800 shadow-xs hover:bg-gray-200 transition-colors " \
             "dark:bg-gray-700 dark:text-gray-100 dark:hover:bg-gray-600"
    ) { "Cohort progress →" }
  end

  # Link to the capability attainment heatmap. Same audience as the cohort
  # roll-up — see AssessmentCyclePolicy#attainment?.
  def attainment_link
    a(
      href: attainment_assessment_cycle_path(@cycle),
      class: "inline-flex items-center rounded-md bg-gray-100 px-3 py-1.5 text-sm font-semibold " \
             "text-gray-800 shadow-xs hover:bg-gray-200 transition-colors " \
             "dark:bg-gray-700 dark:text-gray-100 dark:hover:bg-gray-600"
    ) { "Capability attainment →" }
  end

  def close_button
    form(
      action: close_assessment_cycle_path(@cycle),
      method: "post",
      class: "inline",
      data: { turbo_confirm: "Close this cycle? All enrolled participants will be withdrawn." }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-3 py-1.5 " \
               "text-sm font-semibold text-white shadow-xs hover:bg-red-700 " \
               "transition-colors"
      ) { "Close cycle" }
    end
  end

  def metadata_card
    render Components::Kit::Card.new(title: "Details") do |card|
      card.body do
        dl(class: "grid grid-cols-1 sm:grid-cols-2 gap-4 text-sm") do
          meta_row("Framework", framework_label)
          meta_row(framework_version_label, framework_version_value)
          cycle_type_row
          planned_end_row
          div do
            dt(class: "text-gray-600 dark:text-gray-300") { "Opened at" }
            dd(class: "mt-0.5 font-medium text-gray-900 dark:text-white") do
              local_time(@cycle.opened_at)
            end
          end
          if @cycle.closed_at
            div do
              dt(class: "text-gray-600 dark:text-gray-300") { "Closed at" }
              dd(class: "mt-0.5 font-medium text-gray-900 dark:text-white") do
                local_time(@cycle.closed_at)
              end
            end
          end
        end
      end
    end
  end

  def meta_row(label, value)
    div do
      dt(class: "text-gray-600 dark:text-gray-300") { label }
      dd(class: "mt-0.5 font-medium text-gray-900 dark:text-white") { value }
    end
  end

  def cycle_type_row
    div do
      dt(class: "text-gray-600 dark:text-gray-300") { "Cycle type" }
      dd(class: "mt-0.5") do
        render Views::AssessmentCycles::CycleTypeFrame.new(cycle: @cycle, is_admin: @is_admin)
      end
    end
  end

  def planned_end_row
    div do
      dt(class: "text-gray-600 dark:text-gray-300") { "Target completion" }
      dd(class: "mt-0.5") do
        render Views::AssessmentCycles::CyclePlannedEndFrame.new(cycle: @cycle, is_admin: @is_admin)
      end
    end
  end

  def framework_label
    @framework&.name || "Framework unavailable"
  end

  # Singular "Framework version" when the cycle has only spanned one
  # version; "Framework versions" when it has rolled forward across
  # multiple publishes (`v1–v3`). The label change cues the reader
  # that what follows is a range, not a single integer.
  def framework_version_label
    rolled_forward? ? "Framework versions" : "Framework version"
  end

  def framework_version_value
    if rolled_forward?
      "v#{@cycle.framework_version}–v#{@cycle.latest_framework_version}"
    else
      "v#{@cycle.framework_version}"
    end
  end

  def rolled_forward?
    @cycle.latest_framework_version &&
      @cycle.latest_framework_version > @cycle.framework_version
  end

  def participants_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Participants") do |card|
        card.body do
          if @cycle.participations.any?
            participants_table
          else
            p(class: "text-sm text-gray-600 dark:text-gray-300") do
              "No participants enrolled yet."
            end
          end
        end
      end
    end
  end

  def participants_table
    div(class: "overflow-x-auto") do
      table(class: "min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm") do
        thead do
          tr do
            th(class: "py-2 text-left font-semibold text-gray-600 dark:text-gray-300") { "Name" }
            th(class: "py-2 text-left font-semibold text-gray-600 dark:text-gray-300") { "Email" }
            th(class: "py-2 text-left font-semibold text-gray-600 dark:text-gray-300") { "Status" }
            th(class: "py-2 text-left font-semibold text-gray-600 dark:text-gray-300") { "Enrolled" }
            th(class: "py-2 text-left font-semibold text-gray-600 dark:text-gray-300") { "Aligned" }
            th(class: "py-2") { "" } if @is_admin && @cycle.open?
          end
        end
        tbody(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          @cycle.participations.each { |participant| participant_row(participant) }
        end
      end
    end
  end

  def participant_row(participant)
    tr do
      td(class: "py-2 text-gray-900 dark:text-white") do
        plain participant.person&.name || "(unknown)"
      end
      td(class: "py-2 text-gray-600 dark:text-gray-300") do
        plain participant.person&.email || "—"
      end
      td(class: "py-2") do
        render Components::Kit::Badge.new(
          participant.status.humanize,
          variant: STATUS_VARIANTS.fetch(participant.status, :default)
        )
      end
      td(class: "py-2 text-gray-600 dark:text-gray-300") do
        if participant.enrolled_at
          local_time(participant.enrolled_at)
        else
          plain "—"
        end
      end
      td(class: "py-2 text-gray-600 dark:text-gray-300") do
        if participant.aligned_at
          local_time(participant.aligned_at)
        else
          plain "—"
        end
      end
      if @is_admin && @cycle.open? && participant.status != "withdrawn"
        td(class: "py-2 text-right") { unenroll_button(participant) }
      elsif @is_admin && @cycle.open?
        td(class: "py-2")
      end
    end
  end

  def unenroll_button(participant)
    form(
      action: assessment_cycle_enrollment_path(@cycle, participant),
      method: "post",
      class: "inline",
      data: { turbo_confirm: "Unenroll this participant?" }
    ) do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "text-xs text-red-700 hover:text-red-700 transition-colors"
      ) { "Unenroll" }
    end
  end

  def enroll_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Enroll participants") do |card|
        card.body do
          if @eligible_people.any?
            div(class: "space-y-4") do
              enroll_form
              bulk_enroll_form
            end
          else
            p(class: "text-sm text-gray-600 dark:text-gray-300") do
              "No eligible people — everyone assigned to this framework is already enrolled."
            end
          end
        end
      end
    end
  end

  def bulk_enroll_form
    form(
      action: bulk_assessment_cycle_enrollments_path(@cycle),
      method: "post",
      class: "flex items-center justify-between pt-4 border-t border-gray-200 dark:border-gray-700",
      data: { turbo_confirm: "Enroll all #{@eligible_people.size} eligible #{'person'.pluralize(@eligible_people.size)}?" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "Enroll everyone assigned to this framework in one go."
      end
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-gray-800 hover:bg-gray-900 " \
               "px-3 py-2 text-sm font-semibold text-white shadow-xs transition-colors"
      ) { "Enroll all #{@eligible_people.size}" }
    end
  end

  def enroll_form
    form(
      action: assessment_cycle_enrollments_path(@cycle),
      method: "post",
      class: "flex items-end gap-3"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      div(class: "flex-1") do
        label(
          for: "enrollment_person_id",
          class: "block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1"
        ) { "Person" }
        select(
          id: "enrollment_person_id",
          name: "enrollment[person_id]",
          class: "block w-full rounded-sm border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white"
        ) do
          @eligible_people.each do |person|
            option(value: person.id) { person.name }
          end
        end
      end
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-3 py-2 " \
               "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 transition-colors"
      ) { "Enroll" }
    end
  end
end
