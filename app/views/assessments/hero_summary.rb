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
  def initialize(scoring:, categories:, person_level:, merged_levels:,
                 assessment_id:, context: :self, viewer_is_manager: false,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil,
                 assessee_name: nil, viewer_can_rate: true, alignment_locked: false,
                 thresholds: {})
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
    return unless config && config[:items].any?

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
          continue_assessing_cta(target) if target && @viewer_can_rate
          coverage_chip if @context != :alignment && !coverage_complete?
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
      class: "mt-1 text-[11px] text-gray-600 dark:text-gray-300 underline decoration-dotted " \
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
      div(class: "flex items-start justify-between gap-4") do
        div(class: "min-w-0 flex-1") do
          h2(class: "text-xl font-bold text-gray-900 dark:text-white") { priming_headline }
          p(class: "text-sm text-gray-600 dark:text-gray-300 mt-1") { priming_gloss }
          div(class: "mt-3") { priming_cta(target) } if target && @viewer_can_rate
        end
        div(class: "text-right shrink-0") do
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
    if !@viewer_can_rate
      # View-only chain ancestor — an imperative "Rate …" would prompt an
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
    level_code = level_code(@person_level) || "L#{@person_level}"
    unless @viewer_can_rate
      return "The score appears once at least half of these #{level_code} capabilities are rated."
    end

    whose = @context == :self ? "your" : "these"
    "Rate at least half of #{whose} #{level_code} capabilities and the score appears."
  end

  # Thin bar filling toward the unlock point (not 100%), with the concrete
  # target spelled out — "Score unlocks at 6" reads as a closer, more
  # motivating goal than an abstract percentage.
  def coverage_progress_bar
    target = unlock_target
    fill = target.positive? ? [ current_level_rated.to_f / target, 1.0 ].min : 1.0

    div(class: "mt-2 w-32 ml-auto") do
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
      [ scores_at_next, next_code ]
    else
      [ scores_here, current_code ]
    end
  end

  def gap_scores = gap_target.first
  def gap_code = gap_target.last

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
  def weakest(scores, limit = 3)
    scores.sort_by { |sid, score| [ score[:score].to_f, assessed_score(sid, Float::INFINITY) ] }.first(limit)
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
        list_label: "Gap to #{current_code}",
        items: weakest(scores_here),
        border: "border-red-300 dark:border-red-700",
        accent: "text-red-700 dark:text-red-300",
        caps: caps_by_id }
    when :progressing
      { state_label: "#{state_label(:progressing)} toward #{current_code}",
        list_label: "Gap to #{current_code}",
        items: weakest(scores_here),
        border: "border-amber-300 dark:border-amber-700",
        accent: "text-amber-700 dark:text-amber-300",
        caps: caps_by_id }
    when :performing
      # Meeting the current bar, below the mastery waypoint. The gap that
      # matters is at L+1 — a capability at +0.0 current is meeting today;
      # if its L+1 is unrated (contribution -1.0 there) it is the real gap.
      { state_label: "#{state_label(:performing)} #{current_code} · #{progress_label}",
        list_label: "Gap to #{gap_code}",
        items: weakest(gap_scores),
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
      blocked = primary_scoring.dig(:promotion_readiness, :blocked_at_next_level) || []
      blocked_scores = scores_at_next.slice(*blocked)
      items = blocked_scores.any? ? weakest(blocked_scores) : weakest(gap_scores)
      { state_label: "#{state_label(:mastering)} #{current_code} · #{progress_label}",
        list_label: "Gap to #{gap_code}",
        items: items,
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
        list_label: "Gap to #{current_code}",
        items: weakest(scores_here),
        border: "border-gray-200 dark:border-gray-700",
        accent: "text-gray-600 dark:text-gray-400",
        caps: caps_by_id }
    end
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

        div(class: "flex items-center justify-between gap-2 py-0.5") do
          span(class: "min-w-0 flex-1 truncate text-sm text-gray-700 dark:text-gray-300") do
            cap_data[:capability].name
          end
          weight_chip(cap_data[:weight], suffix: "hero-#{stable_id}")
          span(class: "text-sm font-bold tabular-nums shrink-0 #{tone_text(score[:state])}",
               title: state_label(score[:state])) do
            "#{percent(score[:score])}%"
          end
        end
      end
    end
  end

  # The first capability at the person's current level whose primary
  # frequency hasn't been recorded yet. Used to gate the Continue CTA
  # and to embed the target capability for the JS jump.
  def next_unrated_capability
    @next_unrated_capability ||= @categories
      .flat_map { |cat| cat[:capabilities] }
      .find do |cap_data|
        cell = cap_data[:cells][@person_level]
        cell && primary_cell_frequency(cell).blank?
      end
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
      blocked = readiness[:blocked_at_next_level] || []
      if blocked.any?
        span(class: "text-xs text-gray-600 dark:text-gray-300") do
          "Blocked by #{blocked.size} #{'capability'.pluralize(blocked.size)} at #{next_label}"
        end
      end
    end
  end

  def continue_assessing_cta(target)
    render Views::Assessments::ContinueAssessingLink.new(
      capability_stable_id: target[:capability].stable_id,
      level_ordinal: @person_level,
      label: "Continue",
      classes: "inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-medium " \
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
      blocked = (primary_scoring[:capability_statuses] || {}).values.count(:blocked)
      if blocked.positive?
        "#{subject} held back at #{current_code} by #{blocked} blocked #{'capability'.pluralize(blocked)}."
      else
        "#{subject} close to #{current_code} expectations."
      end
    else
      "Below #{current_code} expectations — focus areas highlighted below."
    end
  end

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
    if @context == :self
      "You're"
    elsif @assessee_name.present?
      "#{@assessee_name.split.first} is"
    else
      "They're"
    end
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
