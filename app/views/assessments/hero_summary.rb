# frozen_string_literal: true

# Sticky hero summary card replacing the scoring sidebar.
#
# Carries `id="scoring-panel"` so the existing rating controller Turbo
# Stream responses update it in-place. Renders three bands:
# - Hero header (verdict + percentage) — always visible
# - Strengths / Lift middle band — collapses on scroll via CSS
#   scroll-driven animation (see `.hero-collapsible` in
#   `app/assets/tailwind/application.css`)
# - Bottom line (promotion pill + CTA) — always visible
#
# No JS controller — the middle-band collapse is pure CSS
# (`animation-timeline: scroll(root)`). Browsers without scroll-driven
# animation support (~5% in 2026) keep the band expanded at all scroll
# positions; the hero is still functional, just static.
#
class Views::Assessments::HeroSummary < Views::Base
  include Views::Assessments::Concerns::ScoreScale
  include Views::Assessments::Concerns::DefinedTerms

  # Fraction of current-level capabilities that must be rated before the
  # score + verdict are trustworthy enough to show. Below this, an unrated
  # cell scores as 0.0 ("never demonstrated") in PersonDevelopment::Scoring,
  # so a near-empty assessment would render a punitive "Below expectations"
  # verdict that only means "you haven't rated yet". Until the threshold is
  # met we show a neutral coverage-progress hero instead.
  COVERAGE_UNLOCK_THRESHOLD = 0.5

  # Rows a gap list shows before it points at the rest. The band collapses
  # on scroll, so it stays short; the "+N more" line says it is not whole.
  GAP_ROWS = 3


  # @param scoring [Hash] effective scoring
  # @param self_scoring [Hash, nil]
  # @param manager_scoring [Hash, nil]
  # @param aligned_scoring [Hash, nil]
  # @param categories [Array<Hash>]
  # @param person_level [Integer]
  # @param merged_levels [Array<Hash>]
  # @param assessment_id [String]
  # @param context [Symbol]
  # @param viewer_is_manager [Boolean] whether the viewer is the manager-side
  #   party — in alignment the secondary percentages lead with the viewer's
  #   own perspective (Mgr first for the manager, Self first for the assessee)
  # @param assessee_name [String, nil]
  # @param viewer_can_rate [Boolean] whether the viewer can act on the
  #   "rate" prompts (assessee, recorded manager, or active delegate).
  #   False for view-only manager-chain ancestors — the priming hero then
  #   renders passive copy and every rate-CTA is withheld.
  # @param thresholds [Hash] the framework's own bands, so the definitions
  #   name its numbers rather than the shipped 80/95/150
  # @param alignment_locked [Boolean] the participant is fully `aligned` —
  #   the hero then presents the agreed record only, withholding the
  #   Self/Mgr secondary percentages and divergent verdict labels. The
  #   inputs remain visible on drill-in (the expansion panel's secondary
  #   lines) and in the activity feed; the glanceable surface reads as one
  #   formal outcome. Only consulted in :alignment context.
  # @param ratings_frozen [Boolean] self and manager ratings are frozen
  #   (home alignment has started). Outside :alignment nothing on the page
  #   can then be rated, so the hero stops asking.
  # @param lens [Assessments::Lens, nil] the role and level the page is read
  #   against. Off the record, the verdict reads conditionally ("Against PM3
  #   you'd be…") and the priming state counts what the role adds; always,
  #   a meeting score links to the next level as a lens.
  def initialize(scoring:, categories:, person_level:, merged_levels:,
                 assessment_id:, context: :self, viewer_is_manager: false,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil,
                 assessee_name: nil, viewer_can_rate: true, alignment_locked: false,
                 thresholds: {}, lens: nil, ratings_frozen: false)
    @lens = lens
    @ratings_frozen = ratings_frozen
    @scoring = scoring
    @viewer_is_manager = viewer_is_manager
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @categories = categories
    @person_level = person_level
    @merged_levels = merged_levels
    @assessment_id = assessment_id
    @context = context
    @assessee_name = assessee_name
    @viewer_can_rate = viewer_can_rate
    @alignment_locked = alignment_locked
    @underperforming_threshold = thresholds[:underperforming]
    @meeting_threshold = thresholds[:meeting]
    @mastery_threshold = thresholds[:mastering]
  end

  def view_template
    ratio = primary_scoring[:performance_ratio] || 0.0
    div(id: "scoring-panel",
        class: "mb-6 rounded-xl border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 overflow-hidden",
        data: { performance_pct: (ratio * 100).round(0) }) do
      if current_level_total.zero?
        unscorable_header
      elsif coverage_unlocked?
        hero_header
      else
        priming_header
      end
    end
  end

  private

  # ── Bands ──

  # Always visible at the top. The verdict + gloss + bottom-line stack
  # share the left column; the big number + bar occupy the right
  # column. The two columns sit side-by-side so the hero card is just
  # tall enough to fit whichever column is taller — no wasted vertical
  # space below the big number.
  def hero_header
    div(class: "px-5 py-4") { header_row }
  end

  # Collapses on scroll. `.hero-collapsible` carries the CSS
  # scroll-driven animation that drives its inner content height +
  # opacity from full → 0 over the first 240px of document scroll.
  # The wrapper itself has no padding — padding lives on an inner
  # element so animating only the wrapper's height doesn't cascade
  # padding-block changes into a layout-flicker loop.
  #
  # Renders a single state-driven panel (not two competing
  # strengths/lift columns). The performance state picks the
  # headline + tone; the capability list is the evidence for it.
  #
  # Lives in the header's LEFT column, under the gloss, so it sits beside
  # the number + bar rather than below the whole row — a full-width band
  # under the taller right column left a blank block beside the headline.
  def middle_band
    config = state_panel_config
    return unless config && (config[:items].any? || config[:gap_list])

    div(class: "hero-collapsible") do
      div do
        div(class: "pt-3") { state_panel(config) }
      end
    end
  end

  def header_row
    ratio = primary_scoring[:performance_ratio] || 0.0
    pct = percent(ratio)
    target = next_unrated_capability

    # Below `sm` the headline stacks above the number + bar (which then
    # share one row); side by side, the 176px bar left the headline a
    # one-word-per-line column and pushed the document past the viewport.
    div(class: "flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-6") do
      div(class: "min-w-0 flex-1") do
        # Headline + actions on one line — "Continue" used to sit on a
        # third row, and the promotion pill on a fourth. Inline-baseline
        # collapses everything into a single visual rhythm and frees ~50
        # vertical pixels in the always-visible band.
        div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-1") do
          h2(class: "text-xl font-bold text-gray-900 dark:text-white") { verdict_headline }
          promotion_pill
          next_level_lens_link
          continue_assessing_cta(target) if target && can_rate?
          coverage_chip if @context != :alignment && !coverage_complete?
          to_confirm_chip if coverage_complete? && can_rate?
        end
        # Gloss + divergent secondary verdicts share one line as long
        # as they fit; flex-wrap drops the secondaries below on narrow
        # viewports rather than the previous fixed two-line stack.
        gloss_and_secondaries
        middle_band
      end
      div(class: "flex items-end justify-between gap-3 sm:flex-col sm:items-end sm:shrink-0") do
        # The number defines itself where it is read, rather than in a help
        # page nobody opens (#414).
        defined_term(:score, label: "#{pct}%", align: :right,
                     trigger_class: "text-4xl font-bold leading-none #{performance_color}")
        div(class: "text-right") do
          score_bar(ratio)
          secondary_percents
          explainer_trigger
        end
      end
    end
  end

  # Opens the root-mounted drawer with this viewer's own arithmetic. Small
  # and quiet: it is an answer for the person who wants one, not a call to
  # action competing with "Continue".
  def explainer_trigger
    button(
      type: "button",
      class: "mt-1 inline-flex min-h-6 items-center text-[11px] text-gray-600 dark:text-gray-300 underline decoration-dotted " \
             "underline-offset-2 hover:text-gray-900 dark:hover:text-white cursor-pointer " \
             "rounded-sm focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
      data: { action: "modal#open",
              modal_target_id: Views::Assessments::ScoreExplainerModal::ID }
    ) { "How is this calculated?" }
  end

  # ── Unscorable (no expectations at the assessed level) ──
  #
  # A level whose expectations are not published yet has nothing to score;
  # the engine returns 0.0 and would otherwise read as a red "Below".
  def unscorable_header
    div(class: "px-5 py-4") do
      h2(class: "text-xl font-bold text-gray-900 dark:text-white") { "Nothing to score at #{current_code} yet" }
      p(class: "text-sm text-gray-600 dark:text-gray-300 mt-1") do
        "No behavioural expectations are defined at #{current_code} for this role, so there is no score to show."
      end
    end
  end

  # ── Priming state (coverage below the unlock threshold) ──
  #
  # Shown before enough current-level capabilities are rated to make the
  # score meaningful. Neutral framing (never red), the score and gap panel
  # are withheld, and the "rate next" action is promoted from a chip to the
  # primary affordance. Mirrors header_row's two-column layout: prompt +
  # CTA on the left, coverage fraction + progress on the right.
  def priming_header
    target = next_unrated_capability

    div(class: "px-5 py-4") do
      # Stacks below `sm`, like the scored header: side by side, a phone left
      # the headline a one-word-per-line column.
      div(class: "flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4") do
        div(class: "min-w-0 flex-1") do
          h2(class: "text-xl font-bold text-gray-900 dark:text-white") { priming_headline }
          p(class: "text-sm text-gray-600 dark:text-gray-300 mt-1") { priming_gloss }
          div(class: "mt-3") { priming_cta(target) } if target && can_rate?
        end
        div(class: "sm:text-right shrink-0") do
          span(class: "text-4xl font-bold leading-none text-gray-900 dark:text-white tabular-nums") do
            "#{current_level_rated}/#{current_level_total}"
          end
          div(class: "text-xs text-gray-500 dark:text-gray-400 uppercase tracking-wide") { "rated" }
          coverage_progress_bar
        end
      end
    end
  end

  def priming_headline
    return lens_priming_headline if new_to_role_count.positive?

    if !can_rate?
      # View-only chain ancestor, or ratings frozen — an imperative "Rate …" would prompt an
      # action this viewer isn't permitted to take.
      @assessee_name.present? ? "No score for #{@assessee_name.split.first} yet" : "No score yet"
    elsif @context == :self
      "Rate yourself to see your score"
    elsif @assessee_name.present?
      "Rate #{@assessee_name.split.first} to see their score"
    else
      "Rate to see the score"
    end
  end

  def priming_gloss
    return lens_priming_gloss if new_to_role_count.positive? && !can_rate_new_cells?

    level_code = level_code(@person_level) || "L#{@person_level}"
    unless can_rate?
      return "The score appears once at least half of these #{level_code} capabilities are rated."
    end

    whose = @context == :self ? "your" : "these"
    "Rate at least half of #{whose} #{level_code} capabilities and the score appears."
  end

  # ── The lens (ADR-22) ──

  def off_record?
    @lens.present? && !@lens.home?
  end

  # Current-level capabilities the record doesn't read — what a lens role
  # adds, and what the reader has to rate before the score means anything.
  def new_to_role_count
    return 0 unless off_record?

    @new_to_role_count ||= @categories.flat_map { |cat| cat[:capabilities] }
      .count { |cap| cap[:cells][@person_level] && cap[:in_home_role] == false }
  end

  # Whether the viewer can act on a "rate" prompt here: a rating participant,
  # with ratings not frozen by alignment (which only :alignment escapes —
  # its agreed values stay open).
  def can_rate?
    @viewer_can_rate && !(@ratings_frozen && @context != :alignment)
  end

  # Both parties rate what a lens adds (ADR-22): the manager's ratings there
  # stay private until alignment against the role starts.
  def can_rate_new_cells?
    can_rate?
  end

  def lens_priming_headline
    count = new_to_role_count
    noun = "#{count} #{'capability'.pluralize(count)} #{count == 1 ? 'is' : 'are'} new to this role"
    if can_rate_new_cells?
      "#{noun} — rate #{count == 1 ? 'it' : 'them'} to see #{@context == :self ? 'your' : 'the'} score"
    else
      "No score against #{@lens.code} yet"
    end
  end

  def lens_priming_gloss
    count = new_to_role_count
    reason = if @ratings_frozen
      "ratings are frozen once alignment against #{@lens.code} has started."
    else
      "only #{@assessee_name.present? ? @assessee_name.split.first : 'the assessee'} and their manager can rate them."
    end
    "#{count} of these #{@lens.code} capabilities #{count == 1 ? 'is' : 'are'} new to this role; #{reason}"
  end

  # "See yourself as E4 →" once a score meets its level — the next level of
  # the role being read, as a lens. A link out of the scoring frame, so it
  # targets the page.
  def next_level_lens_link
    return unless @lens && next_level?
    return unless %i[performing mastering eligible].include?(primary_scoring[:performance_state])

    next_ordinal = levels_above.first[:ordinal]
    who = @context == :self ? "yourself" : (@assessee_name.to_s.split.first.presence || "them")
    a(href: assessment_path(@assessment_id, @lens.params_for(role_id: @lens.role.role_id, ordinal: next_ordinal)),
      data: { turbo_frame: "_top" },
      class: "text-xs font-medium text-primary-ink hover:underline rounded-sm " \
             "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary") do
      "See #{who} as #{next_code} →"
    end
  end

  # Thin bar filling toward the unlock point (not 100%), with the concrete
  # target spelled out — "Score unlocks at 6" reads as a closer, more
  # motivating goal than an abstract percentage.
  def coverage_progress_bar
    target = unlock_target
    fill = target.positive? ? [ current_level_rated.to_f / target, 1.0 ].min : 1.0

    div(class: "mt-2 w-32 sm:ml-auto") do
      div(class: "h-1.5 rounded-full bg-gray-200 dark:bg-gray-700 overflow-hidden") do
        div(class: "h-full rounded-full bg-gray-900 dark:bg-white",
            style: "width: #{(fill * 100).round}%") { }
      end
      div(class: "text-[11px] text-gray-500 dark:text-gray-400 mt-1") do
        "Score unlocks at #{target}"
      end
    end
  end

  def priming_cta(target)
    render Views::Assessments::ContinueAssessingLink.new(
      capability_stable_id: target[:capability].stable_id,
      level_ordinal: @person_level,
      label: "Rate next capability",
      classes: "inline-flex items-center gap-1 px-3 py-1.5 rounded-md text-sm font-semibold " \
               "bg-gray-900 dark:bg-white text-white dark:text-gray-900 " \
               "hover:bg-gray-800 dark:hover:bg-gray-100 transition-colors"
    )
  end

  # Small muted "X of Y rated" badge shown in the unlocked header while the
  # assessment is still incomplete, so the partial score reads as honest.
  def coverage_chip
    span(class: "text-xs text-gray-500 dark:text-gray-400 tabular-nums") do
      "#{current_level_rated} of #{current_level_total} rated"
    end
  end

  # Once every cell holds a value, the work left is confirming the carried
  # ones; this chip names it and jumps to the first (#480). Before then the
  # Continue CTA leads, so the two never compete.
  def to_confirm_chip
    target = next_carried_capability
    return unless target

    render Views::Assessments::ContinueAssessingLink.new(
      capability_stable_id: target[:capability].stable_id,
      level_ordinal: @person_level,
      label: "#{carried_to_confirm.size} to confirm",
      classes: "#{Components::Shared::ToConfirmChip::CLASSES} min-h-6 gap-1 hover:bg-amber-50 dark:hover:bg-amber-950"
    )
  end

  # ── Coverage helpers ──

  # Cells at the person's current level across every bound capability —
  # the denominator for coverage. The verdict is about this level, so
  # coverage is measured here rather than across the whole matrix.
  def current_level_cells
    @current_level_cells ||= @categories
      .flat_map { |cat| cat[:capabilities] }
      .filter_map { |cap| cap[:cells][@person_level] }
  end

  def current_level_total
    current_level_cells.size
  end

  def current_level_rated
    @current_level_rated ||= current_level_cells.count { |cell| primary_cell_frequency(cell).present? }
  end

  def coverage_complete?
    current_level_rated >= current_level_total
  end

  # Number of rated current-level capabilities needed to reveal the score.
  def unlock_target
    (current_level_total * COVERAGE_UNLOCK_THRESHOLD).ceil
  end

  # Whether the score + verdict are trustworthy enough to show. Alignment
  # context keeps the scoring hero unconditionally (individual ratings are
  # frozen by then and coverage is high by construction). A role with no
  # current-level cells unlocks too, to avoid a permanently-stuck prompt.
  def coverage_unlocked?
    return true if @context == :alignment
    return true if current_level_total.zero?

    coverage_ratio >= COVERAGE_UNLOCK_THRESHOLD
  end

  def coverage_ratio
    return 0.0 if current_level_total.zero?

    current_level_rated.to_f / current_level_total
  end

  # Compact one-row gloss: "94% of E3 demonstrated · 38% of the way to E4."
  #
  # The other perspectives are deliberately NOT spelled out here as state
  # words. They already read as percentages under the number, beside the
  # one they differ from, and a second "Self: Below expectations" in the
  # same card says the same thing twice in more space.
  def gloss_and_secondaries
    p(class: "text-sm text-gray-600 dark:text-gray-300 mt-1") { verdict_gloss }
  end

  # Builds the single state-driven panel for the middle band. Picks the
  # headline, list source, and tone from `performance_state`.
  # Returns nil when there are no scored capabilities to back any framing.
  #
  # Every headline leads with the tenant's own word for the state (#415) and
  # then qualifies it, so a renamed state never lands mid-sentence: "Meeting
  # E3 · 62% of the way to E4", "Advancing E3 · …".
  # The capabilities a gap list may name, scored at the level the panel
  # points at. Non-scorable ones are dropped: a capability with no
  # expectation at that level owes nothing there, and its unavoidable 0
  # would otherwise rank as the worst thing on the page.
  def scores_here
    @scores_here ||= scorable(primary_scoring[:capability_scores] || {})
  end

  def scores_at_next
    @scores_at_next ||= scorable(primary_scoring[:capability_scores_at_next_level] || {})
  end

  # The scores a "Gap to …" list is filled from, and the level code that
  # names it — always the same level. A next level that carries no
  # expectations yet has nothing to be short of, so the list falls back to
  # the assessed level AND says so: labelling assessed-level scores "Gap
  # to E4" would read a 100% at E3 as E4 demonstrated in full.
  def gap_target
    @gap_target ||= if scores_at_next.any? && next_code
      [ scores_at_next, next_code, levels_above.first[:ordinal] ]
    else
      [ scores_here, current_code, @person_level ]
    end
  end

  def gap_scores = gap_target[0]
  def gap_code = gap_target[1]
  def gap_ordinal = gap_target[2]

  def scorable(scores)
    scores.select { |_, score| score[:scorable] }
  end

  # Three rows, weakest first — the shape every "Gap to …" list takes.
  #
  # Ties are broken on the assessed level, because they are common and not
  # incidental: nothing is rated at the next level until someone starts
  # working there, so a whole gap list can sit at 0% of it. Among
  # capabilities equally unshown above, the one weakest at the level the
  # person is standing on has the furthest to go, so it leads.
  def weakest(scores, limit = GAP_ROWS)
    scores.sort_by { |sid, score| [ score[:score].to_f, assessed_score(sid, Float::INFINITY), sid ] }.first(limit)
  end

  # Every capability still short of the level, weakest first, with
  # `lead_ids` (blocked ones) ranked ahead of the rest. A capability
  # demonstrated in full there is not a gap, however low it would sort, so
  # it never pads a short list (#471). The stable_id tie-break keeps the
  # cut between the shown rows and "+N more" from reshuffling on reload.
  def ranked_gaps(scores, caps, lead_ids: [])
    gaps = scores.select { |sid, score| caps.key?(sid) && gap?(score) }
    leading = gaps.slice(*lead_ids)
    weakest(leading, leading.size) + weakest(gaps.except(*lead_ids), gaps.size)
  end

  def gap?(score)
    score[:score].to_f < 1.0 || %i[underperforming progressing].include?(score[:state])
  end

  def strongest(scores, limit = 3)
    scores.sort_by { |sid, score| [ -score[:score].to_f, -assessed_score(sid, -Float::INFINITY) ] }.first(limit)
  end

  # Absent from the assessed level means it carries no expectation there,
  # not that it scores zero. The caller says which way that should sort, so
  # a capability nobody asked anything of is never promoted to "weakest"
  # on a number it was never given.
  def assessed_score(stable_id, absent)
    scores_here.dig(stable_id, :score) || absent
  end

  def state_panel_config
    return if scores_here.empty?

    caps_by_id = @categories.flat_map { |c| c[:capabilities] }
                            .index_by { |cap| cap[:capability].stable_id }

    case primary_scoring[:performance_state]
    when :underperforming
      { state_label: "#{state_label(:underperforming)} at #{current_code}",
        **gap_list(ranked_gaps(scores_here, caps_by_id), current_code, @person_level),
        border: "border-red-300 dark:border-red-700",
        accent: "text-red-700 dark:text-red-300",
        caps: caps_by_id }
    when :progressing
      { state_label: "#{state_label(:progressing)} toward #{current_code}",
        **gap_list(ranked_gaps(scores_here, caps_by_id), current_code, @person_level),
        border: "border-amber-300 dark:border-amber-700",
        accent: "text-amber-700 dark:text-amber-300",
        caps: caps_by_id }
    when :performing
      # Meeting the current bar, below the mastery waypoint. The gap that
      # matters is at L+1 — a capability at +0.0 current is meeting today;
      # if its L+1 is unrated (contribution -1.0 there) it is the real gap.
      { state_label: "#{state_label(:performing)} #{current_code} · #{progress_label}",
        **gap_list(ranked_gaps(gap_scores, caps_by_id), gap_code, gap_ordinal),
        border: "border-blue-300 dark:border-blue-700",
        accent: "text-blue-700 dark:text-blue-300",
        caps: caps_by_id }
    when :eligible
      { state_label: next_code ? "#{state_label(:eligible)} · #{next_code}" : state_label(:eligible),
        list_label: "Top contributors",
        items: strongest(scores_here),
        border: "border-green-300 dark:border-green-700",
        accent: "text-green-700 dark:text-green-300",
        caps: caps_by_id }
    when :mastering
      # Past the halfway waypoint — the meaningful question is what is
      # still in the way of promotion. Surface the capabilities with the
      # weakest contribution AT the next level (blocked ones first).
      # Blocked capabilities lead, but they are ranked among themselves
      # like any other gap row: `blocked_at_next_level` is in whatever
      # order the engine collected it, so taking the first three could
      # both omit a worse one and show them out of order.
      # Blocked is a next-level fact, so it only leads a list scored there.
      # An unrated capability holds promotion just the same.
      gaps = ranked_gaps(gap_scores, caps_by_id, lead_ids: gap_ordinal == @person_level ? [] : holding_next_level)
      { state_label: "#{state_label(:mastering)} #{current_code} · #{progress_label}",
        **gap_list(gaps, gap_code, gap_ordinal),
        border: "border-purple-300 dark:border-purple-700",
        accent: "text-purple-700 dark:text-purple-300",
        caps: caps_by_id }
    when :top_of_ladder
      # No band above this level to progress into — show what carries the
      # score rather than a gap nobody can close.
      { state_label: "#{state_label(:top_of_ladder)} #{current_code} · top of the ladder",
        list_label: "Strongest at #{current_code}",
        items: strongest(scores_here),
        border: "border-blue-300 dark:border-blue-700",
        accent: "text-blue-700 dark:text-blue-300",
        caps: caps_by_id }
    else # unknown state
      { state_label: "#{state_label(:performing)} #{current_code}",
        **gap_list(ranked_gaps(scores_here, caps_by_id), current_code, @person_level),
        border: "border-gray-200 dark:border-gray-700",
        accent: "text-gray-600 dark:text-gray-400",
        caps: caps_by_id }
    end
  end

  # The part of a "Gap to …" panel config that every gap state shares: the
  # first rows, and the rest as a count with a way to reach the next one.
  def gap_list(gaps, code, ordinal)
    { list_label: "Gap to #{code}", items: gaps.first(GAP_ROWS), more: gaps.drop(GAP_ROWS),
      gap_code: code, gap_ordinal: ordinal, gap_list: true }
  end

  def state_panel(config)
    div(class: "p-3 rounded-lg border #{config[:border]} bg-gray-50/50 dark:bg-gray-800/30") do
      div(class: "flex items-baseline justify-between gap-3 mb-2") do
        # `min-w-0` is what makes `truncate` actually clip inside a flex
        # row — without it the span grows to fit its content and pushes
        # the sibling delta past the panel's right edge (visible as
        # the deltas being cut off on mobile).
        span(class: "min-w-0 text-xs font-semibold #{config[:accent]} uppercase tracking-wide") do
          config[:state_label]
        end
        span(class: "text-[10px] font-medium text-gray-600 dark:text-gray-300 uppercase tracking-wider shrink-0") do
          config[:list_label]
        end
      end
      # Each row is that capability's own score at the level the panel
      # names — the same scale, and the same tone-by-state rule, as every
      # other number on the page. The signed weight-unit delta this
      # replaced could only be compared against other capabilities, and
      # read -1.0 for every capability nobody had rated at the next level,
      # so a list of three ranked nothing.
      config[:items].each do |stable_id, score|
        cap_data = config[:caps][stable_id]
        next unless cap_data && score

        div(class: "flex items-center gap-2 py-0.5") do
          span(class: "min-w-0 truncate text-sm text-gray-700 dark:text-gray-300") do
            cap_data[:capability].name
          end
          weight_chip(cap_data[:weight], suffix: "hero-#{stable_id}")
          span(class: "ml-auto text-sm font-bold tabular-nums shrink-0 #{tone_text(score[:state])}",
               title: state_label(score[:state])) do
            "#{percent(score[:score])}%"
          end
        end
      end
      gap_list_footer(config) if config[:gap_list]
    end
  end

  # Three rows read as the whole list unless something says otherwise
  # (#471): a reader rated one, watched a fourth take its place, and
  # concluded three were all that stood between them and the level.
  def gap_list_footer(config)
    if config[:items].empty?
      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "No gaps to #{config[:gap_code]} — every capability there is demonstrated in full."
      end
      return
    end
    return if config[:more].empty?

    render Views::Assessments::ContinueAssessingLink.new(
      capability_stable_id: config[:more].first.first,
      level_ordinal: config[:gap_ordinal],
      label: "+#{config[:more].size} more short of #{config[:gap_code]}",
      classes: "mt-1 inline-flex min-h-6 items-center gap-1 text-xs text-gray-600 dark:text-gray-300 " \
               "hover:text-gray-900 dark:hover:text-white hover:underline rounded-sm"
    )
  end

  # The first capability at the person's current level whose primary
  # frequency hasn't been recorded yet. Used to gate the Continue CTA
  # and to embed the target capability for the JS jump.
  def next_unrated_capability
    @next_unrated_capability ||= @categories
      .flat_map { |cat| cat[:capabilities] }
      .find do |cap_data|
        cell = cap_data[:cells][@person_level]
        cell && primary_cell_frequency(cell).blank? && rateable_here?(cell)
      end
  end

  # Current-level capabilities whose value was carried from the last cycle
  # and can still be confirmed here.
  def carried_to_confirm
    @carried_to_confirm ||= @categories
      .flat_map { |cat| cat[:capabilities] }
      .then { |capabilities| Assessments::CarriedCell.at_level(capabilities, @person_level, @context) }
  end

  def next_carried_capability
    carried_to_confirm.first
  end

  # A cell another role's alignment froze (ADR-22) is read-only, so
  # "Continue" must not point at one.
  def rateable_here?(cell)
    return !cell[:agreed_locked] if @context == :alignment

    cell[:frozen_by].nil?
  end

  def primary_cell_frequency(cell)
    case @context
    when :self      then cell[:current_frequency]
    when :manager   then cell[:manager_frequency]
    when :alignment then cell[:aligned_frequency]
    end
  end

  def promotion_pill
    readiness = primary_scoring[:promotion_readiness]
    return unless readiness

    next_label = next_code || "the next level"

    if readiness[:eligible]
      span(class: "text-xs font-medium px-2 py-1 rounded-md " \
                  "bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400 " \
                  "border border-green-200 dark:border-green-800") do
        "Eligible for promotion to #{next_label}"
      end
    else
      reasons = [ blocked_phrase(readiness[:blocked_at_next_level]),
                  unrated_phrase(readiness[:unrated_at_next_level]) ].compact
      if reasons.any?
        span(class: "text-xs text-gray-600 dark:text-gray-300") { "#{reasons.join(' · ')} at #{next_label}" }
      end
    end
  end

  def holding_next_level
    readiness = primary_scoring[:promotion_readiness] || {}
    (readiness[:blocked_at_next_level] || []) + (readiness[:unrated_at_next_level] || [])
  end

  def blocked_phrase(ids)
    return if ids.blank?

    "Blocked by #{ids.size} #{'capability'.pluralize(ids.size)}"
  end

  # Never "blocked": nobody has judged these, they only lack a rating.
  def unrated_phrase(ids)
    return if ids.blank?

    "#{ids.size} #{'capability'.pluralize(ids.size)} to rate"
  end

  def continue_assessing_cta(target)
    render Views::Assessments::ContinueAssessingLink.new(
      capability_stable_id: target[:capability].stable_id,
      level_ordinal: @person_level,
      label: "Continue",
      classes: "inline-flex min-h-6 items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-medium " \
               "bg-gray-900 dark:bg-white text-white dark:text-gray-900 " \
               "hover:bg-gray-800 dark:hover:bg-gray-100 transition-colors"
    )
  end

  # ── Verdict helpers ──

  def verdict_headline
    case primary_scoring[:performance_state]
    when :eligible
      "#{subject} demonstrating #{next_code || 'next-level'} expectations — promotion ready."
    when :mastering
      "#{subject} well on the way to #{next_code}."
    when :top_of_ladder
      "#{subject} meeting #{current_code} expectations — the top of the ladder."
    when :performing
      "#{subject} meeting #{current_code} expectations."
    when :progressing
      progressing_headline
    else
      return "#{subject} below #{current_code} expectations." if off_record?

      "Below #{current_code} expectations — focus areas highlighted below."
    end
  end

  # A blocked capability is a judgement; an unrated one is only waiting, and
  # the headline promises the rating unlocks the level only when the score
  # already clears the bar — otherwise rating it may not be enough.
  def progressing_headline
    blocked = (primary_scoring[:capability_statuses] || {}).values.count(:blocked)
    unrated = (primary_scoring[:unrated] || []).size
    to_rate = "#{unrated} #{'capability'.pluralize(unrated)} still to rate"

    if blocked.positive?
      held = "#{subject} held back at #{current_code} by #{blocked} blocked #{'capability'.pluralize(blocked)}"
      unrated.positive? ? "#{held}, with #{to_rate}." : "#{held}."
    elsif unrated.positive? && primary_scoring[:performance_ratio].to_f >= meeting_bar
      "#{subject} held at #{current_code} until #{unrated} #{'capability'.pluralize(unrated)} " \
        "#{unrated == 1 ? 'is' : 'are'} rated."
    elsif unrated.positive?
      "#{subject} close to #{current_code} expectations, with #{to_rate}."
    else
      "#{subject} close to #{current_code} expectations."
    end
  end

  def meeting_bar = @meeting_threshold || PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD

  # The score's parts in one line — "94% of E3 demonstrated · 38% of the
  # way to E4 · 5% missing below E3" — so the headline number never has to
  # be reverse-engineered.
  def verdict_gloss
    components = primary_scoring[:components] || {}

    parts = [ "#{percent(components[:current])}% of #{current_code} demonstrated" ]
    parts.concat(next_band_phrases(components)) if next_level? && components[:next].to_f.positive?
    parts << "#{percent(1.0 - components[:prior].to_f)}% missing below #{current_code}" if components[:prior].to_f < 1.0
    parts << "no level above #{current_code}" unless next_level?
    "#{parts.join(' · ')}."
  end

  # "38% of the way to E4" — the next-band component, used by the panel
  # headlines that point at the next level.
  def progress_label
    return "no level above" unless next_level?

    next_band_phrases(primary_scoring[:components]).join(" · ")
  end

  # Self view → "You're". Manager / alignment views → "<First name> is",
  # falling back to "They're" when no assessee name is present.
  def subject
    return lens_subject if off_record?

    if @context == :self
      "You're"
    elsif @assessee_name.present?
      "#{@assessee_name.split.first} is"
    else
      "They're"
    end
  end

  # "Against PM3 you'd be" / "Against PM3 Alex would be" — the verdict is
  # what the score would say on that role, not what the record says.
  def lens_subject
    who = if @context == :self then "you'd"
    elsif @assessee_name.present? then "#{@assessee_name.split.first} would"
    else "they'd"
    end
    "Against #{@lens.code} #{who} be"
  end

  # ── Perspective helpers ──

  # Labelled secondary perspectives for the current context. Self is
  # alone in its view (manager/aligned data is scrubbed upstream).
  # Manager view surfaces self; alignment view surfaces both self and
  # manager — ordered **viewer-first** (the viewer's own perspective
  # leads), matching the split-chip corner rule so the two surfaces tell
  # the same story. Nil scorings drop out so a perspective with no ratings
  # yet doesn't render as "0%".
  #
  # Once the agreed record is WHOLE the secondaries drop entirely — the
  # hero reads as one formal outcome rather than three competing scores.
  # "Whole" means every current-level cell carries an agreed value
  # (`coverage_complete?` — the primary frequency in :alignment is the
  # aligned one), which happens the moment the last cell is agreed, NOT
  # only after "Mark alignment complete": user testing showed the lingering
  # Self/Mgr numbers on an all-agreed assessment read as competing scores
  # and confused promotion conversations. While cells remain unagreed the
  # secondaries stay — they are the working material of the conversation.
  # `alignment_locked` still forces the drop for participants completed
  # before the coverage gate existed (aligned status with historical
  # coverage gaps). The self/manager inputs stay reachable in the expansion
  # panel's secondary lines, the level-chip splits, and the activity feed —
  # hidden at a glance, preserved on drill-in.
  def secondary_perspectives
    return [] if @context == :alignment && (@alignment_locked || coverage_complete?)

    @secondary_perspectives ||= case @context
    when :manager   then [ [ "Self", @self_scoring ] ]
    when :alignment then alignment_secondaries
    else []
    end.select { |_, s| s }
  end

  # In alignment both parties' ratings are secondaries (the agreed value is
  # the primary number). Lead with the viewer's own — Mgr first for the
  # manager-side viewer, Self first for the assessee.
  def alignment_secondaries
    self_entry = [ "Self", @self_scoring ]
    mgr_entry  = [ "Mgr", @manager_scoring ]
    @viewer_is_manager ? [ mgr_entry, self_entry ] : [ self_entry, mgr_entry ]
  end

  # Tiny percentage line tucked under "of expected" so the primary
  # number stays dominant. Renders nothing in self view.
  # "Self: 10%" under the number — and the shared amber divergence dot
  # when that perspective lands in a different state, the same marker the
  # category header uses. The gap between two numbers is the message; the
  # dot only says it is worth reading.
  def secondary_percents
    return if secondary_perspectives.empty?

    div(id: "hero-secondary-percents",
        class: "flex items-center justify-end gap-1 text-[11px] " \
               "text-gray-600 dark:text-gray-300 mt-1 tabular-nums") do
      secondary_perspectives.each_with_index do |(label, scoring), i|
        span(class: "text-gray-400 dark:text-gray-500") { "·" } if i.positive?
        if diverges?(scoring)
          span(class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0",
               aria: { hidden: "true" }) { }
        end
        span { "#{label}: #{format_pct(scoring)}" }
      end
    end
  end

  def diverges?(scoring)
    scoring[:performance_state] != primary_scoring[:performance_state]
  end

  def format_pct(scoring)
    "#{((scoring[:performance_ratio] || 0.0) * 100).round(0)}%"
  end

  def primary_scoring
    @primary_scoring ||=
      case @context
      when :self      then @self_scoring || @scoring
      when :manager   then @manager_scoring || @scoring
      when :alignment then @aligned_scoring || @scoring
      else @scoring
      end
  end

  def performance_color
    tone_text(primary_scoring[:performance_state])
  end

  # ── Score bar ──

  # The scale made visible, at hero size: tick-labelled with the level
  # codes, through as many bands as the cap allows (see ScoreBar).
  def score_bar(ratio)
    render Views::Assessments::ScoreBar.new(
      score: ratio, state: primary_scoring[:performance_state], components: primary_scoring[:components],
      merged_levels: @merged_levels, person_level: @person_level, size: :lg, id: "hero-score-bar"
    )
  end
end
