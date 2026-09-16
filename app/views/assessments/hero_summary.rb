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
  # Fraction of current-level capabilities that must be rated before the
  # score + verdict are trustworthy enough to show. Below this, an unrated
  # cell scores as 0.0 ("never demonstrated") in PersonDevelopment::Scoring,
  # so a near-empty assessment would render a punitive "Below expectations"
  # verdict that only means "you haven't rated yet". Until the threshold is
  # met we show a neutral coverage-progress hero instead.
  COVERAGE_UNLOCK_THRESHOLD = 0.5

  # The number and the bar take their colour from the performance STATE, not
  # the raw score, so a 150% held at "progressing" by a blocked capability
  # reads amber like its verdict rather than purple like its number.
  TONE_TEXT = {
    red: "text-red-700 dark:text-red-400",
    amber: "text-amber-700 dark:text-amber-400",
    green: "text-green-700 dark:text-green-400",
    purple: "text-purple-600 dark:text-purple-400"
  }.freeze
  TONE_BAR = { red: "bg-red-500", amber: "bg-amber-500", green: "bg-green-500", purple: "bg-purple-500" }.freeze

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
  # @param alignment_locked [Boolean] the participant is fully `aligned` —
  #   the hero then presents the agreed record only, withholding the
  #   Self/Mgr secondary percentages and divergent verdict labels. The
  #   inputs remain visible on drill-in (the expansion panel's secondary
  #   lines) and in the activity feed; the glanceable surface reads as one
  #   formal outcome. Only consulted in :alignment context.
  def initialize(scoring:, categories:, person_level:, merged_levels:,
                 assessment_id:, context: :self, viewer_is_manager: false,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil,
                 assessee_name: nil, viewer_can_rate: true, alignment_locked: false)
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
        middle_band
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
  def middle_band
    config = state_panel_config
    return unless config && config[:items].any?

    div(class: "hero-collapsible") do
      div do
        div(class: "px-5 pb-5") { state_panel(config) }
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
    div(class: "flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4") do
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
      end
      div(class: "flex items-end justify-between gap-3 sm:flex-col sm:items-end sm:shrink-0") do
        span(class: "text-4xl font-bold leading-none #{performance_color}") { "#{pct}%" }
        div(class: "text-right") do
          score_bar(ratio)
          secondary_percents
        end
      end
    end
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

  # Compact one-row gloss: "94% of E3 demonstrated · 38% of the way to E4. · Self: Below expectations"
  # On narrow viewports the secondary chunk wraps to a second line.
  def gloss_and_secondaries
    secondaries = diverging_secondary_verdicts
    p(class: "text-sm text-gray-600 dark:text-gray-300 mt-1") do
      plain verdict_gloss
      if secondaries.any?
        span(class: "ml-2 text-xs") do
          plain " · "
          plain(secondaries.map { |label, s| "#{label}: #{short_verdict(s)}" }.join(" · "))
        end
      end
    end
  end

  def diverging_secondary_verdicts
    primary = short_verdict(primary_scoring)
    secondary_perspectives.reject { |_, s| short_verdict(s) == primary }
  end

  # Builds the single state-driven panel for the middle band. Picks the
  # headline, list source, and tone from `performance_state`.
  # Returns nil when there are no contributions to back any framing.
  def state_panel_config
    contributions = primary_scoring[:capability_contributions] || {}
    return if contributions.empty?

    caps_by_id = @categories.flat_map { |c| c[:capabilities] }
                            .index_by { |cap| cap[:capability].stable_id }
    sorted = contributions.sort_by { |_, v| -v }

    next_level_contributions = primary_scoring[:capability_contributions_at_next_level] || {}
    sorted_next = next_level_contributions.sort_by { |_, v| -v }

    case primary_scoring[:performance_state]
    when :underperforming
      { state_label: "Underperforming at #{current_code}",
        list_label: "Gap to #{current_code}",
        items: sorted.last(3).reverse,
        border: "border-red-300 dark:border-red-700",
        accent: "text-red-700 dark:text-red-300",
        caps: caps_by_id }
    when :progressing
      { state_label: "Progressing toward #{current_code}",
        list_label: "Gap to #{current_code}",
        items: sorted.last(3).reverse,
        border: "border-amber-300 dark:border-amber-700",
        accent: "text-amber-700 dark:text-amber-300",
        caps: caps_by_id }
    when :performing
      # Meeting the current bar, below the mastery waypoint. The gap that
      # matters is at L+1 — a capability at +0.0 current is meeting today;
      # if its L+1 is unrated (contribution -1.0 there) it is the real gap.
      { state_label: "Performing at #{current_code} · #{progress_label}",
        list_label: next_code ? "Gap to #{next_code}" : "Gap to #{current_code}",
        items: next_level_contributions.any? ? sorted_next.last(3).reverse : sorted.last(3).reverse,
        border: "border-blue-300 dark:border-blue-700",
        accent: "text-blue-700 dark:text-blue-300",
        caps: caps_by_id }
    when :eligible
      { state_label: next_code ? "Eligible for promotion to #{next_code}" : "Eligible for promotion",
        list_label: "Top contributors",
        items: sorted.first(3),
        border: "border-green-300 dark:border-green-700",
        accent: "text-green-700 dark:text-green-300",
        caps: caps_by_id }
    when :mastering
      # Past the halfway waypoint — the meaningful question is what is
      # still in the way of promotion. Surface the capabilities with the
      # weakest contribution AT the next level (blocked ones first).
      blocked = primary_scoring.dig(:promotion_readiness, :blocked_at_next_level) || []
      blocked_items = blocked.first(3).map { |sid| [ sid, next_level_contributions[sid] || 0.0 ] }
      items = blocked_items.any? ? blocked_items : sorted_next.last(3).reverse
      { state_label: "Mastering #{current_code} · #{progress_label}",
        list_label: next_code ? "Gap to #{next_code}" : "Top contributors",
        items: items.any? ? items : sorted.first(3),
        border: "border-purple-300 dark:border-purple-700",
        accent: "text-purple-700 dark:text-purple-300",
        caps: caps_by_id }
    when :top_of_ladder
      # No band above this level to progress into — show what carries the
      # score rather than a gap nobody can close.
      { state_label: "Meeting #{current_code} · top of the ladder",
        list_label: "Strongest at #{current_code}",
        items: sorted.first(3),
        border: "border-blue-300 dark:border-blue-700",
        accent: "text-blue-700 dark:text-blue-300",
        caps: caps_by_id }
    else # unknown state
      { state_label: "Performing at #{current_code}",
        list_label: "Gap to #{current_code}",
        items: sorted.last(3).reverse.select { |_, v| v < 0 },
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
      config[:items].each do |stable_id, value|
        cap_data = config[:caps][stable_id]
        next unless cap_data

        div(class: "flex items-center justify-between gap-2 py-0.5") do
          span(class: "min-w-0 truncate text-sm text-gray-700 dark:text-gray-300") do
            cap_data[:capability].name
          end
          span(class: "text-sm font-bold tabular-nums shrink-0 #{contribution_color(value)}") do
            sprintf("%+.1f", value.to_f)
          end
        end
      end
    end
  end

  # Returns the level code for an ordinal in the merged level set, or
  # nil when the ordinal isn't in the role's ladder (e.g. asking for
  # @person_level + 1 when the person is already at the top). Callers
  # branch on nil to swap the headline for a top-of-ladder framing.
  def level_code(ordinal)
    @merged_levels.find { |l| l[:ordinal] == ordinal }&.dig(:level_code)
  end

  def contribution_color(value)
    if value >= 0.5
      "text-green-700 dark:text-green-400"
    elsif value > -0.5
      "text-gray-600 dark:text-gray-300"
    elsif value > -1.5
      "text-amber-700 dark:text-amber-400"
    else
      "text-red-700 dark:text-red-400"
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
    parts.concat(next_band_phrases) if next_level? && components[:next].to_f.positive?
    parts << "#{percent(1.0 - components[:prior].to_f)}% missing below #{current_code}" if components[:prior].to_f < 1.0
    parts << "no level above #{current_code}" unless next_level?
    "#{parts.join(' · ')}."
  end

  # "38% of the way to E4" — the next-band component, used by the panel
  # headlines that point at the next level.
  def progress_label
    return "no level above" unless next_level?

    next_band_phrases.join(" · ")
  end

  # The next-band component as level-by-level copy. With the default cap it
  # is one phrase ("38% of the way to E4"); with a wider cap a whole band
  # reads "E4 demonstrated in full" and the remainder names the level after.
  def next_band_phrases
    nxt = (primary_scoring[:components] || {})[:next].to_f
    whole = [ nxt.floor, levels_above.size ].min
    phrases = whole.positive? ? [ "#{code_above(whole - 1)} demonstrated in full" ] : []
    remainder = nxt - whole
    if levels_above[whole] && (remainder.positive? || phrases.empty?)
      phrases << "#{percent(remainder)}% of the way to #{code_above(whole)}"
    end
    phrases
  end

  def percent(value)
    (value.to_f * 100).round(0)
  end

  # ── Level codes ──
  #
  # The assessed level's code and the levels above it — what every piece of
  # copy names. `levels_above` is the view's one source for "is there a band
  # above": the same role ladder the engine scores, in order, so a gap in
  # the ordinals cannot make the copy and the number disagree.
  def current_code
    @current_code ||= level_code(@person_level) || "L#{@person_level}"
  end

  def levels_above
    @levels_above ||= @merged_levels.select { |l| l[:ordinal] > @person_level }.sort_by { |l| l[:ordinal] }
  end

  def next_code
    levels_above.first&.dig(:level_code)
  end

  # The code of the level `index` steps above the assessed one.
  def code_above(index)
    levels_above[index]&.dig(:level_code) || "+#{index + 1}"
  end

  def next_level?
    levels_above.any?
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
  def secondary_percents
    return if secondary_perspectives.empty?

    div(id: "hero-secondary-percents",
        class: "text-[11px] text-gray-600 dark:text-gray-300 mt-1 tabular-nums") do
      plain(secondary_perspectives.map { |label, s| "#{label}: #{format_pct(s)}" }.join(" · "))
    end
  end

  def format_pct(scoring)
    "#{((scoring[:performance_ratio] || 0.0) * 100).round(0)}%"
  end

  def short_verdict(scoring)
    case scoring[:performance_state]
    when :eligible then "Promotion ready"
    when :mastering then "Mastering"
    when :performing, :top_of_ladder then "Meeting expectations"
    when :progressing then "Almost there"
    else "Below expectations"
    end
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
    TONE_TEXT.fetch(tone)
  end

  def performance_bar_color
    TONE_BAR.fetch(tone)
  end

  def tone
    case primary_scoring[:performance_state]
    when :eligible, :mastering then :purple
    when :performing, :top_of_ladder then :green
    when :progressing then :amber
    else :red
    end
  end

  # ── Score bar ──

  # The scale made visible: the left half is the assessed level (0–100),
  # the right half the next one (100–200), with the level codes as tick
  # labels — so the number explains itself before any copy does. At the
  # top of the ladder there is no next band, so the bar is a single
  # 0–100 segment.
  def score_bar(ratio)
    bands = score_bands
    max = 100 * (1 + bands)
    pct = percent(ratio)
    fill = ([ pct, max ].min.to_f / max * 100).round(1)
    label = if bands.positive?
      "#{pct}% — 100% is #{current_code} expectations, #{max}% is #{code_above(bands - 1)}"
    else
      "#{pct}% — 100% is #{current_code} expectations, the top of the ladder"
    end

    # 144px beside the number fits a 375px card; 176px clipped the last tick.
    div(id: "hero-score-bar", class: "mt-2 w-36 sm:w-44 ml-auto") do
      div(class: "relative h-1.5 rounded-full bg-gray-200 dark:bg-gray-700 overflow-hidden",
          role: "progressbar",
          aria: { valuenow: [ pct, max ].min, valuemin: 0, valuemax: max, label: label }) do
        div(class: "h-full rounded-full #{performance_bar_color}", style: "width: #{fill}%") { }
        (1..bands).each do |i|
          span(class: "absolute inset-y-0 w-0.5 bg-white dark:bg-gray-900",
               style: "left: #{(100.0 * i / (bands + 1)).round(2)}%", aria: { hidden: "true" }) { }
        end
      end
      div(class: "mt-1 flex justify-between text-[10px] text-gray-600 dark:text-gray-300 tabular-nums",
          aria: { hidden: "true" }) do
        span { "0" }
        span { "100% · #{current_code}" }
        (1..bands).each { |i| span { "#{100 * (i + 1)}% · #{code_above(i - 1)}" } }
      end
    end
  end

  # How many levels above the assessed one the bar runs through — the
  # engine's `bands_above` (the ladder above, windowed by the cap), so a
  # framework with a cap of 2 gets a 0–300 bar rather than a clamped 0–200.
  def score_bands
    return 0 unless next_level?

    (primary_scoring.dig(:components, :bands_above) || 1).to_i.clamp(1, levels_above.size)
  end
end
