# frozen_string_literal: true

# Score by cohort — the third overview tab: every calibrated person as an
# initialed dot on a 0–125% axis, grouped by assessed level and coloured by
# WHO rated them, so "Raj's people cluster low" is pre-attentive before a
# single number is read (docs/architecture/calibration-sessions.md →
# "Score by cohort").
#
# The axis grammar is the divergence board's — positioned initialed dots on
# a track — and the metric is the assessment hero's own "% of expected"
# ({CalibrationSessions::CohortScores}). A signal to discuss, never a
# ranking to publish: the coverage gate keeps unrated people out of the
# distribution ("4 of 12 rated", not a fake low score), carried-majority
# dots wear the dashed disclosure, and the why-panel reframes a low dot as
# a calibration question by naming the rater's own tendency next to it.
class Views::CalibrationSessions::CohortView < Views::Base
  include Views::CalibrationSessions::Glossary
  include Views::CalibrationSessions::RaterColours

  AXIS_MAX_PCT = 125
  # Dots closer than this (in % points) drop to a second lane instead of
  # overlapping — the board's exactly-overlapping-dots nit, addressed here.
  LANE_NUDGE_PCT = 5

  # @param session [CalibrationSession]
  # @param cohorts [Array<Hash>] {CalibrationSessions::CohortScores#call}[:cohorts]
  # @param raters [Array<Hash>] OverviewStats rater rows — colour order + the
  #   why-panel's tendency context
  # @param people [Hash{String => Person}]
  # @param selected_person_id [String, nil] the open why-panel's person
  # @param why [Hash, nil] {CalibrationSessions::CohortScores#why_for}
  def initialize(session:, cohorts:, raters:, people:, selected_person_id: nil, why: nil)
    @session = session
    @cohorts = cohorts
    @raters = raters
    @people = people
    @selected_person_id = selected_person_id
    @why = why
  end

  def view_template
    render Components::Kit::Card.new do |card|
      card.body do
        h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          "Score by cohort"
        end
        div(class: "mt-1 flex flex-wrap items-center gap-x-1 text-xs text-gray-600 dark:text-gray-300") do
          defined_term(:pct_of_expected)
          plain "per person, grouped by assessed level — a signal to discuss, not a ranking."
        end

        if @cohorts.empty?
          empty_state
        else
          legend
          @cohorts.each { |cohort| cohort_block(cohort) }
        end
      end
    end
  end

  private

  def empty_state
    p(class: "mt-4 text-sm text-gray-600 dark:text-gray-300") do
      "Nobody in the population is enrolled at a level yet — cohorts fill in from the cycle's enrollments."
    end
  end

  def legend
    div(class: "mt-3 flex flex-wrap gap-x-4 gap-y-1") do
      @raters.each_with_index do |rater, index|
        div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
          span(class: "inline-block h-3 w-3 rounded-full #{rater_dot_class(index)}", aria: { hidden: "true" })
          plain person_name(rater[:participant_id])
        end
      end
      div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
        span(class: "inline-block h-2.5 w-2.5 rounded-full border-2 border-dashed " \
                    "border-gray-900 dark:border-white", aria: { hidden: "true" })
        plain "mostly carried"
      end
    end
  end

  def cohort_block(cohort)
    div(class: "mt-5 border-t border-gray-100 dark:border-gray-800 pt-4") do
      cohort_header(cohort)
      plotted = cohort[:people].select { |dot| dot[:unlocked] }
      axis(cohort, plotted) if plotted.any?
      gated_row(cohort[:people].reject { |dot| dot[:unlocked] })
      why_panel(cohort) if selected_in?(cohort)
    end
  end

  def cohort_header(cohort)
    div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-1") do
      span(class: "text-xs font-bold rounded-md border border-gray-200 dark:border-gray-700 " \
                  "bg-gray-50 dark:bg-gray-900 px-2 py-0.5 text-gray-900 dark:text-white") do
        "L#{cohort[:ordinal]}"
      end
      span(class: "text-xs text-gray-600 dark:text-gray-300") do
        plain "#{cohort[:people].size} #{'person'.pluralize(cohort[:people].size)}"
        if cohort[:median_pct]
          plain " · "
          defined_term(:cohort_median, suffix: cohort[:ordinal].to_s,
                       label: "median #{cohort[:median_pct]}%")
        end
      end
    end
  end

  # A 0–125% track: labelled reference line at 100%, a median tick, one
  # initialed dot per unlocked person. The text equivalent rides each dot's
  # aria-label — position and colour are never the only carriers.
  def axis(cohort, plotted)
    div(class: "overflow-x-auto") do
      div(class: "relative mt-6 h-16 min-w-[480px]") do
        span(class: "absolute left-0 right-0 top-[30px] h-1.5 rounded-full bg-gray-100 dark:bg-gray-700")
        reference_line
        median_tick(cohort[:median_pct]) if cohort[:median_pct]
        lanes(plotted).each { |dot, lane| render_dot(dot, lane) }
      end
    end
  end

  def reference_line
    span(class: "absolute top-2 bottom-1 w-px bg-gray-300 dark:bg-gray-600",
         style: "left: #{position_pct(100)}%") do
      span(class: "absolute -top-4 left-1/2 -translate-x-1/2 whitespace-nowrap " \
                  "text-[10px] text-gray-600 dark:text-gray-300") do
        "100% — meets expectations"
      end
    end
  end

  def median_tick(median_pct)
    span(class: "absolute top-[24px] h-[18px] w-0.5 rounded bg-gray-900 dark:bg-white opacity-60",
         style: "left: #{position_pct(median_pct)}%",
         title: "Cohort median: #{median_pct}%")
  end

  # dot => lane (0 top, 1 bottom). A dot landing within LANE_NUDGE_PCT of
  # the previous one drops a lane so near-ties stay countable.
  def lanes(plotted)
    last_pct = nil
    last_lane = 1
    plotted.map do |dot|
      lane = if last_pct && (dot[:pct] - last_pct).abs < LANE_NUDGE_PCT
        last_lane.zero? ? 1 : 0
      else
        0
      end
      last_pct = dot[:pct]
      last_lane = lane
      [ dot, lane ]
    end
  end

  def render_dot(dot, lane)
    name = person_name(dot[:person_id])
    a(
      href: cohort_path(cohort_person: dot[:person_id]),
      class: "absolute inline-flex h-11 w-11 -ml-[22px] items-center justify-center",
      style: "left: #{position_pct(dot[:pct])}%; top: #{lane.zero? ? 9 : 31}px",
      title: "#{name} · #{dot[:pct]}% of expected",
      aria: { label: dot_description(dot, name) }
    ) do
      span(
        class: "inline-flex h-7 w-7 items-center justify-center rounded-full text-[10px] " \
               "font-semibold text-white dark:text-gray-900 border-2 " \
               "#{dot[:carried_majority] ? 'border-dashed border-gray-900 dark:border-white' : 'border-white dark:border-gray-800'} " \
               "#{rater_dot_class(rater_index(dot[:rater_id]))} " \
               "#{'ring-2 ring-offset-2 ring-gray-900 dark:ring-white dark:ring-offset-gray-800' if dot[:person_id] == @selected_person_id}"
      ) { initials(name) }
    end
  end

  def dot_description(dot, name)
    base = "#{name} — #{dot[:pct]}% of expected, rated by #{person_name(dot[:rater_id])}"
    base += ", #{dot[:carried_count]} of #{dot[:rated]} ratings carried forward" if dot[:carried_count].positive?
    "#{base}. Open to see why."
  end

  # The coverage gate's honest face: no dot, a "score unlocks at N" chip.
  def gated_row(gated)
    return if gated.empty?

    div(class: "mt-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300") do
      gated.each do |dot|
        span(class: "inline-flex items-center gap-1.5 rounded-full border border-dashed " \
                    "border-gray-300 dark:border-gray-600 px-2.5 py-1") do
          plain person_name(dot[:person_id])
          plain " · "
          if dot[:total].zero?
            plain "no behaviours at this level"
          else
            plain "#{dot[:rated]} of #{dot[:total]} rated — "
            defined_term(:score_gate, suffix: dot[:person_id],
                         label: "score unlocks at #{dot[:unlock_target]}")
          end
        end
      end
    end
  end

  def selected_in?(cohort)
    @why && cohort[:people].any? { |dot| dot[:person_id] == @selected_person_id }
  end

  # The drill-into-why: what pulls this person's score down and up, each
  # linking into the capability drill-in with their card open — composing
  # with the existing surface rather than growing a second grid. The
  # rater-context line ties the tendency strip to this view: a low dot
  # under a harsh rater is a calibration question, not a verdict.
  def why_panel(cohort)
    dot = cohort[:people].find { |d| d[:person_id] == @selected_person_id }
    name = person_name(dot[:person_id])

    div(class: "mt-4 rounded-lg border border-gray-200 dark:border-gray-700 " \
               "bg-gray-50 dark:bg-gray-900 px-4 py-3") do
      div(class: "flex flex-wrap items-baseline justify-between gap-2") do
        div(class: "flex flex-wrap items-baseline gap-2") do
          span(class: "text-sm font-semibold text-gray-900 dark:text-white") { name }
          span(class: "text-sm font-bold text-gray-900 dark:text-white tabular-nums") do
            "#{dot[:pct]}% of expected"
          end
        end
        a(href: cohort_path(cohort_person: nil),
          class: "inline-flex min-h-11 items-center px-2 text-xs text-gray-600 " \
                 "dark:text-gray-300 hover:underline") { "Close" }
      end
      p(class: "mt-0.5 text-xs text-gray-600 dark:text-gray-300") do
        plain "Rated by #{person_name(dot[:rater_id])} · #{dot[:rated]} of #{dot[:total]} rated"
        plain " · #{dot[:carried_count]} carried" if dot[:carried_count].positive?
      end

      why_columns
      rater_context(dot)
    end
  end

  def why_columns
    div(class: "mt-3 grid grid-cols-1 sm:grid-cols-2 gap-x-7 gap-y-2") do
      why_column("Pulling the score down", @why[:weakest],
                 empty: "Nothing below expectations.")
      why_column("Pulling it up", @why[:strongest],
                 empty: "Nothing above expectations yet.")
    end
  end

  def why_column(heading, entries, empty:)
    div do
      h3(class: "text-[11px] font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        heading
      end
      if entries.empty?
        p(class: "mt-1.5 text-xs text-gray-600 dark:text-gray-300") { empty }
      else
        entries.each { |entry| why_row(entry) }
      end
    end
  end

  def why_row(entry)
    div(class: "flex items-center gap-2 border-t border-gray-200 dark:border-gray-700 py-1.5 text-sm") do
      span(class: "min-w-0 flex-1 text-gray-900 dark:text-white") { entry[:name] }
      span(class: "tabular-nums font-bold #{delta_classes(entry[:delta])}") do
        sprintf("%+.1f", entry[:delta])
      end
      a(
        href: calibration_session_capability_path(@session, entry[:stable_id],
                                                  person: @selected_person_id),
        class: "text-xs text-gray-700 dark:text-gray-200 underline underline-offset-2 " \
               "whitespace-nowrap min-h-11 inline-flex items-center"
      ) { "Open drill-in →" }
    end
  end

  def delta_classes(delta)
    if delta.negative?
      delta <= -1.0 ? "text-red-700 dark:text-red-300" : "text-amber-700 dark:text-amber-300"
    else
      "text-green-700 dark:text-green-300"
    end
  end

  # "Mia rates +0.41 vs org mean overall" — part of a low score may be the
  # rater's tendency, which is the conversation this room exists to have.
  def rater_context(dot)
    rater = @raters.find { |row| row[:participant_id] == dot[:rater_id] }
    return unless rater && rater[:org_delta]

    p(class: "mt-3 rounded-md bg-amber-100 dark:bg-amber-900/25 px-3 py-2 text-xs " \
             "text-amber-800 dark:text-amber-200 max-w-xl") do
      plain "Rater context: #{person_name(dot[:rater_id])} rates "
      strong { sprintf("%+.2f vs org mean", rater[:org_delta]) }
      plain " across their whole team — part of this score may be tendency, not #{person_name(dot[:person_id])}."
    end
  end

  # Cohort-tab links, preserving the view param; nil clears the why-panel.
  def cohort_path(cohort_person:)
    calibration_session_path(@session, { view: "cohort", cohort_person: cohort_person }.compact)
  end

  def rater_index(rater_id)
    @rater_index ||= @raters.each_with_index.to_h { |rater, index| [ rater[:participant_id], index ] }
    @rater_index.fetch(rater_id, 0)
  end

  def position_pct(pct)
    ((pct.clamp(0, AXIS_MAX_PCT).to_f / AXIS_MAX_PCT) * 100).round(1)
  end

  def person_name(person_id)
    @people[person_id]&.name || "Unknown"
  end

  def initials(name)
    name.to_s.split.map(&:first).first(2).join.upcase
  end
end
