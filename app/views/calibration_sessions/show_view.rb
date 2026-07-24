# frozen_string_literal: true

# One calibration session — the draft setup surface (curate participants
# + population, readiness gate, start) and the read-only rosters once
# started/closed. The live overview & drill-in surfaces are separate
# increments; see docs/architecture/calibration-sessions.md.
class Views::CalibrationSessions::ShowView < Views::Base
  STATUS_VARIANTS = { "draft" => :warning, "started" => :success, "closed" => :default }.freeze
  STATUS_LABELS = { "draft" => "Draft", "started" => "Live", "closed" => "Closed" }.freeze

  # @param session [CalibrationSession]
  # @param cycle [AssessmentCycle, nil]
  # @param people [Hash{String => Person}] every person referenced, by id
  # @param participant_ids [Array<String>]
  # @param calibrant_ids [Array<String>]
  # @param groups [Array<[String, Array<String>]>] [participant_id (nil = other), member person_ids]
  # @param suggestions [Array<Person>] seed people not yet in the population
  # @param readiness [Hash] { enrolled_ids:, manager_complete_ids: }
  # @param add_calibrant_candidates [Array<Person>]
  # @param add_participant_candidates [Array<Person>]
  def initialize(session:, cycle:, people:, participant_ids:, calibrant_ids:,
                 groups:, suggestions:, readiness:,
                 add_calibrant_candidates:, add_participant_candidates:,
                 can_curate:, can_start:, can_close:,
                 user: nil, current_tenant: nil, tenants: [])
    @session = session
    @cycle = cycle
    @people = people
    @participant_ids = participant_ids
    @calibrant_ids = calibrant_ids
    @groups = groups
    @suggestions = suggestions
    @readiness = readiness
    @add_calibrant_candidates = add_calibrant_candidates
    @add_participant_candidates = add_participant_candidates
    @can_curate = can_curate
    @can_start = can_start
    @can_close = can_close
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-4xl mx-auto px-4 py-8") do
        header_row
        readiness_bar
        div(class: "mt-6 grid grid-cols-1 lg:grid-cols-3 gap-6") do
          div(class: "lg:col-span-1") { participants_card }
          div(class: "lg:col-span-2") { population_card }
        end
        live_note unless @session.draft?
      end
    end
  end

  private

  def header_row
    div(class: "flex flex-wrap items-center gap-3") do
      div(class: "flex-1 min-w-0") do
        a(href: calibration_sessions_path, class: "text-sm text-gray-600 dark:text-gray-300 hover:underline") do
          "← Calibration"
        end
        div(class: "mt-1 flex flex-wrap items-center gap-3") do
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @session.name }
          render Components::Kit::Badge.new(
            STATUS_LABELS.fetch(@session.status, @session.status),
            variant: STATUS_VARIANTS.fetch(@session.status, :default)
          )
        end
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
          plain @cycle&.name || "Cycle unavailable"
          plain " · facilitated by #{person_name(@session.facilitator_id)}"
        end
      end
      action_cluster
    end
  end

  def action_cluster
    div(class: "flex items-center gap-2") do
      if @can_start
        form(action: start_calibration_session_path(@session), method: "post",
             data: { turbo_confirm: "Starting freezes the participants and population for the whole session. Start now?" }) do
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          button(type: "submit", class: primary_button_classes) { "Start session" }
        end
      end
      if @can_close
        form(action: close_calibration_session_path(@session), method: "post",
             data: { turbo_confirm: "Closing is permanent — the session becomes its follow-through record. Close?" }) do
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          button(type: "submit", class: secondary_button_classes) do
            @session.draft? ? "Discard session" : "Close session"
          end
        end
      end
    end
  end

  def readiness_bar
    total = @calibrant_ids.size
    rated = (@readiness[:manager_complete_ids] & @calibrant_ids).size
    unenrolled = total - (@readiness[:enrolled_ids] & @calibrant_ids).size

    div(class: "mt-4 rounded-md border border-gray-200 dark:border-gray-700 px-4 py-3") do
      div(class: "flex flex-wrap items-center gap-x-4 gap-y-1 text-sm") do
        span(class: "font-medium text-gray-900 dark:text-white") { "Readiness" }
        span(class: "text-gray-600 dark:text-gray-300") { "#{rated} of #{total} manager-rated" }
        if unenrolled.positive?
          span(class: "text-amber-700 dark:text-amber-300") { "#{unenrolled} not enrolled in the cycle" }
        end
      end
      div(
        class: "mt-2 h-1.5 w-full rounded-full bg-gray-200 dark:bg-gray-700",
        role: "progressbar",
        aria: { valuenow: rated, valuemin: 0, valuemax: [ total, 1 ].max, label: "Manager-rated coverage" }
      ) do
        pct = total.zero? ? 0 : ((rated.to_f / total) * 100).round
        div(class: "h-1.5 rounded-full bg-primary", style: "width: #{pct}%")
      end
    end
  end

  def participants_card
    render Components::Kit::Card.new do |card|
      card.body do
        h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          plain "Participants (#{@participant_ids.size})"
        end
        p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
          plain "Raters in the room — excluded from the population."
        end
        ul(class: "mt-3 space-y-1") do
          @participant_ids.each { |person_id| participant_row(person_id) }
        end
        add_participant_form if @can_curate && @add_participant_candidates.any?
      end
    end
  end

  def participant_row(person_id)
    li(class: "flex items-center justify-between gap-2 rounded-md px-2 py-1.5 hover:bg-gray-50 dark:hover:bg-gray-800") do
      span(class: "text-sm text-gray-900 dark:text-white") { person_name(person_id) }
      if @can_curate
        remove_button(
          calibration_session_participant_path(@session, person_id),
          label: "Remove participant #{person_name(person_id)}"
        )
      end
    end
  end

  def population_card
    render Components::Kit::Card.new do |card|
      card.body do
        h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          plain "Population (#{@calibrant_ids.size})"
        end
        p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
          plain "The people whose ratings this session calibrates."
        end

        @groups.each { |participant_id, member_ids| population_group(participant_id, member_ids) }

        suggestions_section if @can_curate && @suggestions.any?
        add_calibrant_form if @can_curate && @add_calibrant_candidates.any?
      end
    end
  end

  def population_group(participant_id, member_ids)
    return if member_ids.empty?

    div(class: "mt-4") do
      h3(class: "text-xs font-medium text-gray-600 dark:text-gray-300") do
        if participant_id
          plain "#{person_name(participant_id)}'s reports (#{member_ids.size})"
        else
          plain "Added individually / other raters (#{member_ids.size})"
        end
      end
      ul(class: "mt-1 space-y-1") do
        member_ids.each { |person_id| calibrant_row(person_id) }
      end
    end
  end

  def calibrant_row(person_id)
    li(class: "flex items-center justify-between gap-2 rounded-md px-2 py-1.5 hover:bg-gray-50 dark:hover:bg-gray-800") do
      div(class: "flex items-center gap-2 min-w-0") do
        span(class: "text-sm text-gray-900 dark:text-white truncate") { person_name(person_id) }
        readiness_badges(person_id)
      end
      if @can_curate
        remove_button(
          calibration_session_calibrant_path(@session, person_id),
          label: "Remove #{person_name(person_id)} from the population"
        )
      end
    end
  end

  def readiness_badges(person_id)
    unless @readiness[:enrolled_ids].include?(person_id)
      render Components::Kit::Badge.new("Not enrolled", variant: :warning)
      return
    end
    unless @readiness[:manager_complete_ids].include?(person_id)
      render Components::Kit::Badge.new("Unrated", variant: :default)
    end
  end

  def suggestions_section
    div(class: "mt-5 rounded-md border border-dashed border-gray-300 dark:border-gray-600 px-3 py-2") do
      p(class: "text-xs text-gray-600 dark:text-gray-300") do
        plain "Reporting to participants but not in the population:"
      end
      ul(class: "mt-1 space-y-1") do
        @suggestions.each do |person|
          li(class: "flex items-center justify-between gap-2") do
            span(class: "text-sm text-gray-900 dark:text-white") { person.name }
            add_person_button(person.id, label: "Add #{person.name} to the population")
          end
        end
      end
    end
  end

  def add_calibrant_form
    form(action: calibration_session_calibrants_path(@session), method: "post", class: "mt-5 flex items-end gap-2") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      div(class: "flex-1") do
        label(for: "add-calibrant", class: "block text-xs font-medium text-gray-600 dark:text-gray-300") do
          "Add person from your org"
        end
        select(id: "add-calibrant", name: "person_id", class: select_classes) do
          @add_calibrant_candidates.each { |person| option(value: person.id) { person.name } }
        end
      end
      button(type: "submit", class: secondary_button_classes) { "Add" }
    end
  end

  def add_participant_form
    form(action: calibration_session_participants_path(@session), method: "post", class: "mt-4 flex items-end gap-2") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      div(class: "flex-1") do
        label(for: "add-participant", class: "block text-xs font-medium text-gray-600 dark:text-gray-300") do
          "Add participant"
        end
        select(id: "add-participant", name: "person_id", class: select_classes) do
          @add_participant_candidates.each { |person| option(value: person.id) { person.name } }
        end
      end
      button(type: "submit", class: secondary_button_classes) { "Add" }
    end
  end

  def add_person_button(person_id, label:)
    form(action: calibration_session_calibrants_path(@session), method: "post", class: "inline") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "person_id", value: person_id)
      button(type: "submit", class: "text-sm text-primary hover:underline min-h-11 px-2", aria: { label: label }) { "Add" }
    end
  end

  def remove_button(path, label:)
    form(action: path, method: "post", class: "inline shrink-0") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      button(
        type: "submit",
        class: "inline-flex h-11 w-11 items-center justify-center rounded-md text-gray-600 " \
               "dark:text-gray-300 hover:text-red-700 dark:hover:text-red-300",
        aria: { label: label }
      ) do
        span(aria: { hidden: "true" }) { "✕" }
      end
    end
  end

  def live_note
    div(class: "mt-6 rounded-md border border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300") do
      if @session.started?
        plain "Session is live — participants and population are frozen. " \
              "The overview and capability drill-in surfaces are coming next."
      else
        plain "Session closed"
        plain " (#{@session.close_reason == 'cycle_closed' ? 'cycle closed' : 'by facilitator'})"
        plain ". This page is the session's follow-through record."
      end
    end
  end

  def person_name(person_id)
    @people[person_id]&.name || "Unknown person"
  end

  def primary_button_classes
    "inline-flex items-center rounded-md bg-primary px-3 py-2 text-sm font-semibold " \
      "text-white shadow-xs hover:bg-primary/90 focus-visible:outline " \
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
  end

  def secondary_button_classes
    "inline-flex items-center rounded-md border border-gray-300 dark:border-gray-600 " \
      "px-3 py-2 text-sm font-semibold text-gray-900 dark:text-white " \
      "hover:bg-gray-50 dark:hover:bg-gray-800"
  end

  def select_classes
    "mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-white"
  end
end
