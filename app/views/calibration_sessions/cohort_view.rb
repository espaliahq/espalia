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
  # Dots closer than this (in % points) stack into further lanes instead of
  # overlapping — the board's exactly-overlapping-dots nit, addressed here.
  # A real cohort clusters hard (twenty people between 75 and 100), so the
  # packing is greedy k-lane, not a two-lane flip-flop.
  # ≥ the 44px tap-target LINK at the track's 480px min width (12% of a
  # 0–125 axis ≈ 46px there) — a "far enough for the same lane" that still
  # let the later link cover the earlier dot defeated the point.
  LANE_NUDGE_PCT = 12
  MAX_LANES = 4
  # A full 44px per lane: each dot's tap target is 44px high, so anything
  # tighter stacks one lane's links over the lane above and steals its
  # clicks. Airier than the mock — correct beats dense.
  LANE_HEIGHT = 44
  DOT_TOP = 9

  # @param session [CalibrationSession]
  # @param cohorts [Array<Hash>] {CalibrationSessions::CohortScores#call}[:cohorts]
  # @param raters [Array<Hash>] OverviewStats rater rows — colour order + the
  #   why-panel's tendency context
  # @param people [Hash{String => Person}]
  # @param selected_person_id [String, nil] the drawer's inspected person
  # @param pin_ids [Array<String>] drawer pins, preserved on every dot link
  def initialize(session:, cohorts:, raters:, people:, selected_person_id: nil, pin_ids: [])
    @session = session
    @cohorts = cohorts
    @raters = raters
    @people = people
    @selected_person_id = selected_person_id
    @pin_ids = pin_ids
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

  # Colour identifies raters only while the palette can — beyond its six
  # hues the colours cycle and a name-per-swatch legend would be a lie (and
  # at an org-wide session's ~25 raters, a wall). Past that, say so and let
  # initials + hover carry identity, which they do at every size.
  def legend
    div(class: "mt-3 flex flex-wrap gap-x-4 gap-y-1") do
      if @raters.size <= RATER_DOT_CLASSES.size
        # Only raters who own a plotted dot — a swatch promising a dot that
        # exists on no axis is the lie the divergence board's legend rule
        # exists to prevent, and it holds here too.
        @raters.each_with_index do |rater, index|
          next unless plotted_rater_ids.include?(rater[:participant_id])

          div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
            span(class: "inline-block h-3 w-3 rounded-full #{rater_dot_class(index)}", aria: { hidden: "true" })
            plain person_name(rater[:participant_id])
          end
        end
        if plotted_rater_ids.include?(nil)
          div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
            span(class: "inline-block h-3 w-3 rounded-full bg-gray-500 dark:bg-gray-400", aria: { hidden: "true" })
            plain "rated outside this session"
          end
        end
      else
        p(class: "text-xs text-gray-600 dark:text-gray-300") do
          "#{@raters.size} raters — more than the palette's #{RATER_DOT_CLASSES.size} colours, " \
            "so colours repeat; hover a dot for who rated whom."
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
  # aria-label — position and colour are never the only carriers. Height
  # grows with the lanes the cluster needs, so tap targets never overflow
  # into a phantom scrollbar.
  def axis(cohort, plotted)
    placed = lanes(plotted)
    lane_count = placed.map(&:last).max + 1
    # A lane IS one 44px tap-target row, so total height is pure lanes.
    height = DOT_TOP + lane_count * LANE_HEIGHT

    div(class: "overflow-x-auto") do
      div(class: "relative mt-6 min-w-[480px]", style: "height: #{height}px") do
        span(class: "absolute left-0 right-0 top-[30px] h-1.5 rounded-full bg-gray-100 dark:bg-gray-700")
        reference_line
        median_tick(cohort[:median_pct]) if cohort[:median_pct]
        placed.each { |dot, lane| render_dot(dot, lane) }
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

  # dot => lane. Greedy packing: each dot (already sorted by score) takes
  # the first lane whose last occupant is at least LANE_NUDGE_PCT away;
  # a dense cluster stacks downward instead of smearing into a pile. At
  # MAX_LANES the densest ties do overlap — countable is the goal, not a
  # beeswarm.
  def lanes(plotted)
    lane_edges = []
    plotted.map do |dot|
      # Distance on the RENDERED position: two overperformers at 128% and
      # 140% both draw at the 125% cap, so measuring the raw pcts would
      # call them "far apart" and stack their tap targets exactly.
      pct = dot[:pct].clamp(0, AXIS_MAX_PCT)
      lane = lane_edges.index { |edge| (pct - edge).abs >= LANE_NUDGE_PCT }
      lane ||= lane_edges.size < MAX_LANES ? lane_edges.size : (pct.round % MAX_LANES)
      lane_edges[lane] = pct
      [ dot, lane ]
    end
  end

  def render_dot(dot, lane)
    name = person_name(dot[:person_id])
    a(
      href: cohort_path(person: dot[:person_id]),
      class: "absolute inline-flex h-11 w-11 -ml-[22px] items-center justify-center",
      style: "left: #{position_pct(dot[:pct])}%; top: #{DOT_TOP + lane * LANE_HEIGHT}px",
      title: "#{name} · #{dot[:pct]}% of expected",
      aria: { label: dot_description(dot, name) }
    ) do
      span(
        class: "inline-flex h-7 w-7 items-center justify-center rounded-full text-[10px] " \
               "font-semibold text-white dark:text-gray-900 border-2 " \
               "#{dot[:carried_majority] ? 'border-dashed border-gray-900 dark:border-white' : 'border-white dark:border-gray-800'} " \
               "#{dot_fill(dot)} " \
               "#{'ring-2 ring-offset-2 ring-gray-900 dark:ring-white dark:ring-offset-gray-800' if dot[:person_id] == @selected_person_id}"
      ) { initials(name) }
    end
  end

  # Rater colour, or the neutral fill for a dot rated outside the room.
  def dot_fill(dot)
    index = rater_index(dot[:rater_id])
    index ? rater_dot_class(index) : "bg-gray-500 dark:bg-gray-400"
  end

  def dot_description(dot, name)
    rated_by = dot[:rater_id] ? person_name(dot[:rater_id]) : "someone outside this session"
    base = "#{name} — #{dot[:pct]}% of expected, rated by #{rated_by}"
    base += ", #{dot[:carried_count]} of #{dot[:rated]} ratings carried forward" if dot[:carried_count].positive?
    "#{base}. Open in the comparison drawer."
  end

  # The coverage gate's honest face: no dot, a "score unlocks at N" chip.
  def gated_row(gated)
    return if gated.empty?

    div(class: "mt-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300") do
      gated.each do |dot|
        # A gated person still opens in the drawer — the card shows the
        # gate's copy instead of a number.
        a(href: cohort_path(person: dot[:person_id]),
          class: "inline-flex items-center gap-1.5 rounded-full border border-dashed " \
                 "border-gray-300 dark:border-gray-600 px-2.5 py-1 hover:border-gray-500 " \
                 "dark:hover:border-gray-400 min-h-11") do
          plain person_name(dot[:person_id])
          plain " · "
          if dot[:role_missing]
            plain "no role snapshot for this cycle — their assessment still opens from the population list"
          elsif dot[:total].zero?
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

  # Rater ids owning at least one plotted (unlocked) dot; nil marks
  # unattributed dots.
  def plotted_rater_ids
    @plotted_rater_ids ||= @cohorts.flat_map do |cohort|
      cohort[:people].select { |dot| dot[:unlocked] }.map { |dot| dot[:rater_id] }
    end.uniq.to_set
  end

  # Cohort-tab links, preserving the tab and the drawer's pins.
  def cohort_path(person:)
    calibration_session_path(
      @session, { view: "cohort", person: person, pins: @pin_ids.presence }.compact
    )
  end

  # nil for a calibrant no participant is attributed — their dot must NOT
  # wear rater #1's colour (the palette's whole job is "whose judgment is
  # this"; a misattributed hue is worse than none).
  def rater_index(rater_id)
    @rater_index ||= @raters.each_with_index.to_h { |rater, index| [ rater[:participant_id], index ] }
    @rater_index[rater_id]
  end

  # Display position, held off the wrapper's edges: a dot centred at 0% or
  # 125% would hang half its 44px tap target outside the overflow container
  # and get clipped.
  def position_pct(pct)
    ((pct.clamp(0, AXIS_MAX_PCT).to_f / AXIS_MAX_PCT) * 100).clamp(3.0, 97.0).round(1)
  end

  def person_name(person_id)
    @people[person_id]&.name || "Unknown"
  end
end
