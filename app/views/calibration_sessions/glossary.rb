# frozen_string_literal: true

# The calibration vocabulary, defined once.
#
# The session screens invent a vocabulary — *self-gap*, *spread*, *carried*,
# *org mean* — and used to define none of it. A facilitator meeting these on
# a projector, mid-meeting, in front of their EMs has nowhere to look, and a
# metric nobody can define is one the room quietly ignores or misreads as an
# accusation (docs/architecture/calibration-sessions.md → *In-surface
# definitions for the calibration vocabulary*).
#
# One source, so wording can't drift between the strip, the board, and the
# drill-in. Keep these in step with `CalibrationSessions::OverviewStats`,
# which computes them — if a definition here and the code disagree, the code
# is right and the room has been misled.
#
# Mixed into any calibration view: `defined_term(:self_gap)` renders the
# label with its definition attached (see {Components::Kit::DefinitionTip}).
module Views::CalibrationSessions::Glossary
  TERMS = {
    org_mean: {
      label: "Org mean",
      definition: "The mean manager rating across everyone in this session, " \
                  "on the 0–3 frequency scale. Only cells at each person's own " \
                  "assessed level count."
    },
    reports: {
      label: "Reports",
      definition: "How many of this rater's reports are in the session, and how " \
                  "many at-level cells they hold between them. Those cells are " \
                  "the denominator for every percentage on this card."
    },
    rated_cells: {
      label: "n",
      definition: "How many at-level cells this rater has rated — the sample every " \
                  "number on the row is computed from. Below 3 the row shows its " \
                  "numbers but never flags them: a small sample always looks extreme."
    },
    rating_coverage: {
      label: "Rating coverage",
      definition: "The share of at-level cells that carry a manager rating, whether " \
                  "confirmed this cycle or carried from the last one. Every cell " \
                  "rated moves it."
    },
    evidence_coverage: {
      label: "Evidence coverage",
      definition: "The share of at-level cells with at least one piece of linked " \
                  "feedback, counted over every cell — rated or not — so it reads " \
                  "on the same scale as rating coverage. Substantiation is a " \
                  "separate axis from leniency."
    },
    ready: {
      label: "Ready?",
      definition: "The work left before this rater's ratings are ready to calibrate: " \
                  "ready means every cell is rated and confirmed this cycle; “N to " \
                  "confirm” means every cell has a value but N were carried from the " \
                  "last cycle; “N unrated” counts cells still without a rating."
    },
    fully_rated: {
      label: "fully rated",
      definition: "People whose manager has rated every at-level cell and confirmed " \
                  "it this cycle. A stricter count than coverage: one carried or " \
                  "missing cell keeps a person out of it."
    },
    org_delta: {
      label: "vs org mean",
      definition: "This rater's mean minus the org mean — how lenient or harsh " \
                  "they are overall, not on any one capability. ▲ rates above " \
                  "the room, ▼ below."
    },
    distribution: {
      label: "Distribution",
      definition: "How this rater's ratings split across the four frequencies. " \
                  "Two raters can share a mean and still distribute very " \
                  "differently — one hedging to the middle, one going to the ends."
    },
    self_gap: {
      label: "Self-gap",
      definition: "Mean of (manager rating − self rating), over cells where both " \
                  "sides rated. Negative means this rater scores their people " \
                  "below those people's own view of themselves. It is a signal to " \
                  "discuss, not a verdict — they may be the room's most honest rater."
    },
    evidence: {
      label: "Evidence",
      definition: "The share of this rater's rated cells that carry at least one " \
                  "piece of linked feedback. Substantiation is a separate axis " \
                  "from leniency: rating low and backing it is not the same as " \
                  "rating low."
    },
    carried: {
      label: "% carried",
      definition: "The share of at-level cells whose rating was carried forward from " \
                  "the previous cycle and not confirmed this one. Carried ratings are " \
                  "still the rater's ratings and still count everywhere — this says " \
                  "how much the rater has yet to vet."
    },
    spread: {
      label: "spread",
      definition: "The distance between the highest and lowest rater mean on this " \
                  "capability, in frequency bands. Raw disagreement, before any " \
                  "correction."
    },
    raters_disagree: {
      label: "⚠ raters disagree",
      definition: "Disagreement that survives subtracting each rater's overall " \
                  "leniency — so it is about THIS capability, not about who is " \
                  "generally harsh — on a large enough sample to mean something. " \
                  "Often the expectation text is what's unclear, not the people."
    },
    backing: {
      label: "Solid dot = feedback / evidence attached · outlined = unbacked",
      definition: "Fill shows whether the rating rests on recorded observation. " \
                  "Colour is the rating itself, so the two signals never compete. " \
                  "A rater whose high ratings are systematically outlined is one " \
                  "of the most useful things this grid shows."
    },
    # The one term this glossary shares with the assessment side, where the
    # same number is read by the person it describes. The scale's own
    # sentence comes from {Views::Assessments::Glossary} so the two surfaces
    # cannot drift; what is added here is the part that is true only of a
    # cohort — manager ratings only.
    pct_of_expected: {
      label: "% of expected",
      definition: "The same number this person's own assessment shows: how much of what their " \
                  "level expects they already show, across every capability. " \
                  "#{Views::Assessments::Glossary::SCALE_SENTENCE} " \
                  "Manager ratings only, so cohorts compare exactly the judgments being calibrated."
    },
    cohort_median: {
      label: "median",
      definition: "The midpoint of the unlocked scores in this cohort — half sit " \
                  "above it, half below. People whose score is still locked behind " \
                  "the coverage gate aren't counted."
    },
    score_gate: {
      label: "score unlocks",
      definition: "A score only shows once at least half of someone's at-level " \
                  "behaviours carry a manager rating. Below that, the number would " \
                  "read as a judgment when it only means \"not rated yet\"."
    },
    to_confirm: {
      label: "To confirm",
      definition: "Every manager rating for this person is carried from the " \
                  "previous cycle. The work this cycle is to confirm or revise " \
                  "them, not to start from nothing."
    }
  }.freeze

  # Renders the term with its definition attached.
  #
  # @param key [Symbol] a {TERMS} key
  # @param align [Symbol] :left or :right — flip near a viewport edge
  # @param label [String, nil] override the displayed text; the definition is
  #   unchanged (e.g. a column header that reads "Reports" but shows counts)
  # @param trigger_class [String, nil] for a term that already has a visual
  #   form — the "raters disagree" badge keeps its warning colour
  # @param suffix [String, nil] REQUIRED wherever a term repeats on one page
  #   (a spread per capability row, a "To confirm" per person). The id wires
  #   `aria-describedby`, so a duplicate makes every one of them ambiguous —
  #   pass the row's stable id. Terms that appear once (the strip's column
  #   headers) can omit it and keep the short, linkable id.
  def defined_term(key, align: :left, label: nil, trigger_class: nil, suffix: nil)
    term = TERMS.fetch(key)
    render Components::Kit::DefinitionTip.new(
      label || term[:label],
      definition: term[:definition],
      id: [ "calibration-term", key.to_s.tr("_", "-"), suffix ].compact.join("-"),
      align: align,
      trigger_class: trigger_class
    )
  end

  # The warning-badge look, so a term that WAS a badge stays one.
  BADGE_TRIGGER = "inline-flex min-h-11 items-center rounded-full px-2.5 text-xs font-medium " \
                  "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400"
end
