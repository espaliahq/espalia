# frozen_string_literal: true

# The capability drill-in — expectation text per level above a
# rater × level dot grid, with a person card when a dot is opened.
#
# Anonymization is conversation choreography, not privacy control
# (docs/architecture/calibration-sessions.md): dots render anonymous by
# default; opening a dot (`?person=`) IS the reveal, sticky per person in
# sessionStorage via the calibration-reveal Stimulus controller; a
# session-level "Show names" toggle overrides for high-trust rooms.
# Dot fill = evidence backing (solid backed / outlined unbacked), colour =
# the shared frequency palette — the two signals never share a primitive.
class Views::CalibrationSessions::DrillInView < Views::Base
  include Views::Assessments::FrequencyPalette
  include Views::Evidence::Valence

  UNRATED_DOT = "border-2 border-gray-300 dark:border-gray-600"

  RELATION_LABELS = { "self" => "Self", "manager" => "Manager", "peer" => "Peer feedback" }.freeze

  # @param session [CalibrationSession]
  # @param stats [Hash] DrillInStats result
  # @param people [Hash{String => Person}] rater people by id
  # @param person_card [Hash, nil] `{ dot:, ordinal:, rater_id:, evidence: }`
  # @param can_flag [Boolean] whether the viewer can ⚑ flag an expectation
  #   as unclear (facilitator/admin AND the session is live)
  def initialize(session:, stats:, people:, person_card:, can_flag: false,
                 user: nil, current_tenant: nil, tenants: [])
    @session = session
    @stats = stats
    @people = people
    @person_card = person_card
    @can_flag = can_flag
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(
        class: "max-w-5xl mx-auto px-4 py-8",
        data: {
          controller: "calibration-reveal",
          calibration_reveal_session_id_value: @session.id,
          calibration_reveal_reveal_person_value: @person_card&.dig(:dot, :person_id).to_s
        }
      ) do
        header_row
        expectations_card
        grid_card
        person_card_section if @person_card
      end
    end
  end

  private

  def header_row
    div(class: "flex flex-wrap items-center gap-3") do
      div(class: "flex-1 min-w-0") do
        a(href: calibration_session_path(@session),
          class: "text-sm text-gray-600 dark:text-gray-300 hover:underline") { "← #{@session.name}" }
        div(class: "mt-1 flex flex-wrap items-baseline gap-x-3") do
          if @stats[:capability][:category_name]
            span(class: "text-xs font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300") do
              @stats[:capability][:category_name]
            end
          end
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @stats[:capability][:name] }
        end
      end
      button(
        type: "button",
        class: "inline-flex items-center rounded-md border border-gray-300 dark:border-gray-600 " \
               "px-3 py-2 text-sm text-gray-900 dark:text-white hover:bg-gray-50 dark:hover:bg-gray-800",
        data: { action: "calibration-reveal#toggleNamed", calibration_reveal_target: "toggle" }
      ) { "Show names" }
    end
  end

  def expectations_card
    div(class: "mt-5") do
      render Components::Kit::Card.new do |card|
        card.body do
          h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
            "What good looks like"
          end
          dl(class: "mt-2 space-y-2") do
            @stats[:ordinals].each do |ordinal|
              div(class: "flex gap-3") do
                dt(class: "shrink-0 w-8 text-sm font-semibold text-gray-900 dark:text-white") { "L#{ordinal}" }
                dd(class: "flex-1 text-sm text-gray-600 dark:text-gray-300") do
                  plain @stats[:expectations][ordinal] || "No expectation defined at this level."
                  flag_affordance(ordinal)
                end
              end
            end
          end
        end
      end
    end
  end

  # Per-level ⚑ outcome: an already-open clarification (from ANY session —
  # overlapping sessions see each other's flags) renders as a marker; a live
  # session's facilitator gets the flag disclosure with an optional reason.
  # One flag per cell per session — the marker replaces the affordance.
  def flag_affordance(ordinal)
    open_count = @stats[:clarifications][ordinal].to_i
    if open_count.positive?
      div(class: "mt-1 text-xs font-medium text-amber-700 dark:text-amber-300") do
        plain "⚑ Flagged — #{open_count} open #{'clarification'.pluralize(open_count)} on the framework"
      end
    elsif @can_flag
      flag_form(ordinal)
    end
  end

  def flag_form(ordinal)
    details(class: "mt-1") do
      summary(
        class: "inline-flex min-h-11 cursor-pointer items-center text-xs font-medium " \
               "text-gray-600 dark:text-gray-300 hover:text-amber-700 dark:hover:text-amber-300"
      ) { "⚑ Flag expectation as unclear" }
      form(
        action: calibration_session_expectation_flags_path(@session),
        method: "post",
        class: "mt-2 max-w-lg space-y-2"
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
        input(type: "hidden", name: "level_ordinal", value: ordinal)
        textarea(
          id: "flag-reason-#{ordinal}", name: "reason", rows: "2",
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          placeholder: "What is the room reading differently? (optional)",
          aria: { label: "What is unclear about this expectation" }
        )
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-amber-600 px-3 py-2 text-sm " \
                 "font-semibold text-white hover:bg-amber-700 transition-colors"
        ) { "Raise clarification" }
      end
    end
  end

  def grid_card
    div(class: "mt-6") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex flex-wrap items-baseline justify-between gap-2") do
            h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
              "At-level ratings by rater"
            end
            p(class: "text-xs text-gray-600 dark:text-gray-300") do
              plain "Solid dot = feedback / evidence attached · outlined = unbacked · click a dot to discuss"
            end
          end

          div(class: "mt-3 overflow-x-auto") do
            table(class: "w-full text-sm") do
              thead do
                tr(class: "text-left text-xs text-gray-600 dark:text-gray-300") do
                  th(class: "py-1.5 pr-3 font-medium") { "Rater" }
                  @stats[:ordinals].each { |ordinal| th(class: "py-1.5 pr-3 font-medium") { "L#{ordinal}" } }
                end
              end
              tbody do
                @stats[:rows].each { |row| grid_row(row) }
              end
            end
          end

          frequency_legend
        end
      end
    end
  end

  def grid_row(row)
    tr(class: "border-t border-gray-100 dark:border-gray-800 #{'opacity-60' unless row[:in_session]}") do
      td(class: "py-2 pr-3 whitespace-nowrap") do
        span(class: "font-medium text-gray-900 dark:text-white") { rater_label(row) }
        unless row[:in_session]
          span(class: "ml-2 text-xs text-gray-600 dark:text-gray-300") { "(not in session)" }
        end
      end
      @stats[:ordinals].each do |ordinal|
        td(class: "py-2 pr-3") do
          div(class: "flex flex-wrap items-center") do
            (row[:people][ordinal] || []).each { |dot| render_dot(dot, ordinal) }
          end
        end
      end
    end
  end

  # Anonymous by default: the server never puts the member's name in the
  # accessible name — the reveal controller adds it client-side once the
  # dot has been discussed (or the room runs named).
  def render_dot(dot, ordinal)
    base = dot_description(dot, ordinal)
    a(
      href: calibration_session_capability_path(@session, @stats[:capability][:stable_id], person: dot[:person_id]),
      class: "inline-flex h-11 w-11 items-center justify-center",
      aria: { label: "Population member — #{base}. Open to discuss." },
      data: {
        calibration_reveal_target: "dot",
        person_id: dot[:person_id],
        person_name: dot[:name],
        base_label: base
      }
    ) do
      span(class: "h-7 w-7 rounded-full #{dot_classes(dot)}", aria: { hidden: "true" })
    end
  end

  def dot_classes(dot)
    return UNRATED_DOT unless dot[:frequency]

    if dot[:backed]
      CONFIG.fetch(dot[:frequency])[:chip_bg]
    else
      # Outline from the shared palette so an unbacked dot's hue can never
      # drift from the chips/pills for the same frequency.
      "border-2 #{CONFIG.fetch(dot[:frequency])[:border]}"
    end
  end

  def dot_description(dot, ordinal)
    rating = dot[:frequency] ? CONFIG.fetch(dot[:frequency])[:phrase] : "unrated"
    backing = dot[:backed] ? "evidence attached" : "no evidence"
    "L#{ordinal} · #{rating} · #{backing}"
  end

  def frequency_legend
    div(class: "mt-4 flex flex-wrap gap-x-4 gap-y-1") do
      CONFIG.each do |_freq, config|
        div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
          span(class: "inline-block h-3 w-3 rounded-full #{config[:chip_bg]}", aria: { hidden: "true" })
          plain config[:phrase]
        end
      end
      div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
        span(class: "inline-block h-3 w-3 rounded-full #{UNRATED_DOT}", aria: { hidden: "true" })
        plain "Unrated"
      end
    end
  end

  # The opened member's card — rendering it is the reveal, so the name is
  # shown here by design.
  def person_card_section
    dot = @person_card[:dot]
    div(class: "mt-6", id: "calibration-person-card") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex flex-wrap items-start justify-between gap-3") do
            div do
              h2(class: "text-lg font-semibold text-gray-900 dark:text-white") { dot[:name] }
              p(class: "mt-0.5 text-sm text-gray-600 dark:text-gray-300") do
                plain "L#{@person_card[:ordinal]}"
                plain " · rated by #{rater_name(@person_card[:rater_id])}" if @person_card[:rater_id]
              end
            end
            a(
              href: calibration_session_capability_path(@session, @stats[:capability][:stable_id]),
              class: "inline-flex h-11 min-w-11 items-center justify-center px-2 text-sm " \
                     "text-gray-600 dark:text-gray-300 hover:underline",
              aria: { label: "Close person card" }
            ) { "Close" }
          end

          div(class: "mt-3 flex flex-wrap gap-2") do
            rating_pill("Manager", dot[:frequency])
            rating_pill("Self", dot[:self_frequency])
          end

          evidence_section
          revisit_section
        end
      end
    end
  end

  # Value-free revisit ask, on the card because discussing the dot is what
  # earns the outcome. Only for in-session raters (reference points are
  # exempt), only while live; one ask per cell per session.
  def revisit_section
    return unless @person_card[:rater_id]

    div(class: "mt-4 border-t border-gray-100 dark:border-gray-800 pt-3") do
      if @person_card[:revisit_requested]
        p(class: "text-xs font-medium text-amber-700 dark:text-amber-300") do
          plain "Revisit requested — it will appear in #{rater_name(@person_card[:rater_id])}'s assessment activity."
        end
      elsif @can_flag
        revisit_form
      end
    end
  end

  def revisit_form
    details do
      summary(
        class: "inline-flex min-h-11 cursor-pointer items-center text-xs font-medium " \
               "text-gray-600 dark:text-gray-300 hover:text-amber-700 dark:hover:text-amber-300"
      ) { "Ask #{rater_name(@person_card[:rater_id])} to revisit this rating" }
      form(
        action: calibration_session_rating_revisits_path(@session),
        method: "post",
        class: "mt-2 max-w-lg space-y-2"
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "person_id", value: @person_card[:dot][:person_id])
        input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
        input(type: "hidden", name: "level_ordinal", value: @person_card[:ordinal])
        textarea(
          id: "revisit-note", name: "note", rows: "2", required: true,
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          placeholder: "The room's note — what the discussion surfaced (never a target rating)",
          aria: { label: "Discussion note for the revisit request" }
        )
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-amber-600 px-3 py-2 text-sm " \
                 "font-semibold text-white hover:bg-amber-700 transition-colors"
        ) { "Request revisit" }
      end
    end
  end

  def rating_pill(label, frequency)
    config = frequency && CONFIG[frequency]
    classes = config ? config[:pill_bg] : "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"
    span(class: "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-medium #{classes}") do
      plain "#{label}: #{config ? config[:phrase] : 'unrated'}"
    end
  end

  def evidence_section
    div(class: "mt-4") do
      h3(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        "Feedback / Evidence at this behaviour"
      end
      if @person_card[:evidence].empty?
        p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
          plain "None linked — if the room can't answer “what did you see?”, that is the finding."
        end
      else
        ul(class: "mt-2 space-y-3") do
          @person_card[:evidence].each { |item| evidence_row(item) }
        end
      end
    end
  end

  def evidence_row(item)
    li(class: "rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2") do
      div(class: "flex flex-wrap items-center gap-2") do
        valence_badge(item[:valence])
        span(class: "text-xs text-gray-600 dark:text-gray-300") do
          plain RELATION_LABELS.fetch(item[:relation], item[:relation])
          plain " · "
          plain item[:recorded_at].strftime("%b %-d, %Y")
        end
      end
      p(class: "mt-1.5 text-sm text-gray-900 dark:text-white") { item[:content].truncate(280) }
    end
  end

  def rater_label(row)
    row[:rater_id] ? rater_name(row[:rater_id]) : "Other raters"
  end

  def rater_name(rater_id)
    @people[rater_id]&.name || "Unknown"
  end
end
