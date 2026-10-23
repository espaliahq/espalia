# frozen_string_literal: true

# One person's level face in the comparison drawer: their % of expected
# (or the coverage gate's honest copy), what pulls the score down and up
# (each row linking into the capability drill-in with their card open),
# and the rater-tendency context line — the session page's presentation
# of a person, side by side with the pins.
#
# The capability face — the read-only ladder — lives in the drill-in's
# drawer card; a pin is a PERSON, so the same pin shows whichever face
# the current screen calls for.
class Views::CalibrationSessions::CohortDrawerCard < Views::Base
  include Views::CalibrationSessions::Glossary
  include Views::CalibrationSessions::PeopleNames
  # For `tone_text` only — the drill-in rows wear the same colour for a
  # state as the person's own assessment page. The concern's level-code
  # helpers need `@merged_levels` / `@person_level`, which this card does
  # not carry and does not call.
  include Views::Assessments::Concerns::ScoreScale

  # @param session [CalibrationSession]
  # @param dot [Hash] the person's {CalibrationSessions::CohortScores} dot
  # @param why [Hash, nil] weakest/strongest contributions (nil while gated)
  # @param raters [Array<Hash>] OverviewStats rater rows (tendency context)
  # @param people [Hash{String => Person}]
  # @param view [String] the active overview tab, preserved on card links
  # @param pin_ids [Array<String>]
  # @param inspector [Boolean] the just-clicked slot (gets Close)
  # @param inspector_person_id [String, nil] whoever is inspected — card
  #   links must preserve THEM, not swap in this card's person
  # @param max_pins [Integer]
  def initialize(session:, dot:, why:, raters:, people:, view:, pin_ids:,
                 inspector:, inspector_person_id: nil, max_pins:)
    @session = session
    @dot = dot
    @why = why
    @raters = raters
    @people = people
    @view = view
    @pin_ids = pin_ids
    @inspector = inspector
    @inspector_person_id = inspector_person_id
    @max_pins = max_pins
  end

  def view_template
    pinned = @pin_ids.include?(@dot[:person_id])
    div(
      class: "min-w-[320px] max-w-[440px] flex-1 shrink-0 rounded-lg border bg-default " \
             "p-3 h-full overflow-y-auto " \
             "#{pinned ? 'border-compared ring-1 ring-compared' : 'border-default'}",
      data: { drawer_card: @dot[:person_id] }
    ) do
      header_row(pinned)
      score_or_gate
      meta_line
      if @why
        why_columns
        rater_context
      end
    end
  end

  private

  def header_row(pinned)
    div(class: "flex flex-wrap items-start justify-between gap-2") do
      div do
        h2(class: "text-base font-semibold text-default") { person_name(@dot[:person_id]) }
        p(class: "mt-0.5 text-xs text-muted") do
          plain "L#{@dot[:ordinal]}"
          plain " · rated by #{rated_by}" if @dot[:rater_id] || @dot[:unlocked]
        end
      end
      div(class: "flex items-center gap-1") do
        pin_toggle(pinned)
        # ONE dismiss per card: ✕ unpins a pinned card, closes an unpinned
        # inspector — same gesture, "remove this card".
        if @inspector && !pinned
          a(
            href: session_path(person: nil),
            class: "inline-flex h-11 w-11 items-center justify-center text-lg " \
                   "text-muted hover:bg-default-hover rounded-md",
            aria: { label: "Close person card" }
          ) { "×" }
        end
      end
    end
  end

  def pin_toggle(pinned)
    if pinned
      a(
        href: session_path(pins: @pin_ids - [ @dot[:person_id] ]),
        class: "inline-flex h-11 w-11 items-center justify-center text-lg " \
               "text-compared hover:bg-compared-subtle rounded-md",
        aria: { label: "Unpin #{person_name(@dot[:person_id])} from the comparison drawer" }
      ) { "×" }
    elsif @pin_ids.size < @max_pins
      a(
        href: session_path(pins: @pin_ids + [ @dot[:person_id] ]),
        class: "inline-flex min-h-11 items-center px-2 text-sm text-link hover:text-link-hover hover:underline",
        aria: { label: "Pin #{person_name(@dot[:person_id])}" }
      ) { "Pin" }
    end
  end

  # The number when the coverage gate is open; the gate's honest copy when
  # it isn't — a card never shows a misleadingly-low score.
  def score_or_gate
    if @dot[:unlocked]
      p(class: "mt-1 text-2xl font-extrabold tracking-tight text-default tabular-nums") do
        plain "#{@dot[:pct]}%"
        span(class: "ml-1.5 text-xs font-semibold text-muted") { "of expected" }
      end
    elsif @dot[:role_missing]
      p(class: "mt-1 text-sm text-muted") do
        "No role snapshot for this cycle — their assessment still opens from the population list."
      end
    elsif @dot[:total].zero?
      p(class: "mt-1 text-sm text-muted") { "No behaviours at this level." }
    else
      p(class: "mt-1 text-sm text-muted") do
        plain "#{@dot[:rated]} of #{@dot[:total]} rated — "
        defined_term(:score_gate, suffix: "drawer-#{@dot[:person_id]}",
                     label: "score unlocks at #{@dot[:unlock_target]}")
      end
    end
  end

  def meta_line
    return unless @dot[:unlocked]

    p(class: "mt-0.5 text-xs text-muted") do
      plain "#{@dot[:rated]} of #{@dot[:total]} rated"
      plain " · #{@dot[:carried_count]} carried forward" if @dot[:carried_count].positive?
    end
  end

  def why_columns
    div(class: "mt-3 grid grid-cols-1 gap-y-2") do
      why_column("Pulling the score down", @why[:weakest],
                 empty: "Nothing below expectations.")
      why_column("Pulling it up", @why[:strongest],
                 empty: "Nothing above expectations yet.")
    end
  end

  def why_column(heading, entries, empty:)
    div do
      h3(class: "text-[11px] font-semibold uppercase tracking-wide text-muted") do
        heading
      end
      if entries.empty?
        p(class: "mt-1 text-xs text-muted") { empty }
      else
        entries.each { |entry| why_row(entry) }
      end
    end
  end

  def why_row(entry)
    div(class: "flex items-center gap-2 border-t border-default py-1 text-sm") do
      span(class: "min-w-0 flex-1 text-default") { entry[:name] }
      weight_marker(entry[:weight])
      # The same number, scale and tone as this person's own assessment
      # page — this drawer used to speak in the engine's weight units, which
      # only compared against the other rows beside it (#421).
      span(class: "tabular-nums font-bold #{tone_text(entry[:state])}") { "#{entry[:score]}%" }
      a(
        href: calibration_session_capability_path(
          @session, entry[:stable_id],
          person: @dot[:person_id], pins: @pin_ids.presence,
          # Land ON the person card — the reader followed a person's row.
          anchor: "calibration-person-card"
        ),
        class: "text-xs text-muted underline underline-offset-2 " \
               "whitespace-nowrap min-h-11 inline-flex items-center",
        # Off-page link inside the overview frame — without _top, Turbo
        # navigates the FRAME and renders "Content missing".
        data: { turbo_frame: "_top" }
      ) { "Open drill-in →" }
    end
  end

  # Only when it is not 1.0: this drawer compares people, and a capability
  # that counts double drags the score twice as hard — which a percentage
  # on its own hides.
  def weight_marker(weight)
    return unless PersonDevelopment::Scoring.weighted?(weight)

    span(class: "text-[10px] font-medium text-muted shrink-0",
         title: "Counts #{weight_label(weight)} toward the score") do
      weight_label(weight)
    end
  end

  # "Mia rates +0.41 vs org mean overall" — part of a low score may be the
  # rater's tendency, which is the conversation this room exists to have.
  def rater_context
    rater = @raters.find { |row| row[:participant_id] == @dot[:rater_id] }
    return unless rater && rater[:org_delta]

    render Components::Kit::Alert.new(tone: :warning, size: :sm, role: :note, class: "mt-2") do
      plain "Rater context: #{person_name(@dot[:rater_id])} rates "
      strong { sprintf("%+.2f vs org mean", rater[:org_delta]) }
      plain " across their whole team — part of this score may be tendency, not #{person_name(@dot[:person_id])}."
    end
  end

  def rated_by
    @dot[:rater_id] ? person_name(@dot[:rater_id]) : "someone outside this session"
  end

  # Session-page pane links: preserve the active tab, the INSPECTOR (not
  # this card's person — unpinning a pinned card must never swap who the
  # room is inspecting), and every other drawer occupant.
  def session_path(person: @inspector_person_id, pins: @pin_ids)
    calibration_session_path(
      @session, { view: @view, person: person, pins: pins.presence }.compact
    )
  end
end
