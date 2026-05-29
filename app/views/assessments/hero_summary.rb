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
  # @param scoring [Hash] effective scoring
  # @param self_scoring [Hash, nil]
  # @param manager_scoring [Hash, nil]
  # @param aligned_scoring [Hash, nil]
  # @param categories [Array<Hash>]
  # @param person_level [Integer]
  # @param merged_levels [Array<Hash>]
  # @param mastery_threshold [Float]
  # @param meeting_expectation_threshold [Float]
  # @param assessment_id [String]
  # @param context [Symbol]
  # @param assignment [PersonFrameworkAssignment]
  # @param can_start_alignment [Boolean]
  # @param can_complete_alignment [Boolean]
  # @param assessee_name [String, nil]
  def initialize(scoring:, categories:, person_level:, merged_levels:,
                 mastery_threshold:, meeting_expectation_threshold:,
                 assessment_id:, context: :self, assignment: nil,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil,
                 can_start_alignment: false, can_complete_alignment: false,
                 assessee_name: nil)
    @scoring = scoring
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @categories = categories
    @person_level = person_level
    @merged_levels = merged_levels
    @mastery_threshold = mastery_threshold
    @meeting_expectation_threshold = meeting_expectation_threshold
    @assessment_id = assessment_id
    @context = context
    @assignment = assignment
    @can_start_alignment = can_start_alignment
    @can_complete_alignment = can_complete_alignment
    @assessee_name = assessee_name
  end

  def view_template
    ratio = primary_scoring[:performance_ratio] || 0.0
    div(id: "scoring-panel",
        class: "mb-6 rounded-xl border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 overflow-hidden",
        data: { performance_pct: (ratio * 100).round(0) }) do
      hero_header
      middle_band
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
    pct = (ratio * 100).round(0)

    div(class: "flex items-start justify-between gap-4") do
      div(class: "min-w-0 flex-1") do
        h2(class: "text-xl font-bold text-gray-900 dark:text-white") do
          verdict_headline
        end
        p(class: "text-sm text-gray-500 dark:text-gray-400 mt-1") do
          verdict_gloss
        end
        bottom_line
      end
      div(class: "text-right shrink-0") do
        span(class: "text-4xl font-bold leading-none #{performance_color(ratio)}") { "#{pct}%" }
        div(class: "text-xs text-gray-400 dark:text-gray-500 mt-1") { "of expected" }
        progress_bar(ratio)
      end
    end
  end

  def bottom_line
    target = next_unrated_capability
    return unless target || promotion_readiness_visible?

    div(class: "mt-3 flex flex-wrap items-center gap-2") do
      promotion_pill
      continue_assessing_cta(target) if target
    end
  end

  def progress_bar(ratio)
    pct = [ (ratio * 100).round(0), 150 ].min
    width = (pct.to_f / 1.5).round(0)
    div(class: "w-24 bg-gray-200 dark:bg-gray-700 rounded-full h-1.5 mt-2") do
      div(class: "#{performance_bar_color(ratio)} h-1.5 rounded-full",
          style: "width: #{[ width, 100 ].min}%") { }
    end
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
    current_code = level_code(@person_level)
    next_code = level_code(@person_level + 1)

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
      # Above the meeting bar but not yet mastering. The path to
      # mastery is overperformance — rating consistent at L+1 (or
      # beyond) is what actually pushes the ratio past 1.15.
      # Surface capabilities by their NEXT-LEVEL contribution, not
      # current: a capability at +0.0 current is meeting today, but
      # if its L+1 is unrated (contribution -1.0 there) it's the
      # real gap to mastering. Top of ladder falls back to current.
      gap_items = next_level_contributions.any? ? sorted_next.last(3).reverse : sorted.last(3).reverse
      { state_label: "Performing at #{current_code}",
        list_label: "Gap to mastering",
        items: gap_items,
        border: "border-blue-300 dark:border-blue-700",
        accent: "text-blue-700 dark:text-blue-300",
        caps: caps_by_id }
    when :eligible
      { state_label: "Eligible for promotion to #{next_code}",
        list_label: "Top contributors",
        items: sorted.first(3),
        border: "border-green-300 dark:border-green-700",
        accent: "text-green-700 dark:text-green-300",
        caps: caps_by_id }
    when :mastering
      # Already mastering current — the meaningful question is what's
      # still in the way of promotion. Surface the capabilities with
      # the weakest contribution AT the next level (blocked ones
      # first when they exist).
      blocked = primary_scoring.dig(:promotion_readiness, :blocked_at_next_level) || []
      blocked_items = blocked.first(3).map { |sid| [ sid, next_level_contributions[sid] || 0.0 ] }
      items = blocked_items.any? ? blocked_items : sorted_next.last(3).reverse
      { state_label: "Mastering #{current_code}",
        list_label: next_code ? "Gap to promotion to #{next_code}" : "Top contributors",
        items: items.any? ? items : sorted.first(3),
        border: "border-purple-300 dark:border-purple-700",
        accent: "text-purple-700 dark:text-purple-300",
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
        span(class: "text-xs font-semibold #{config[:accent]} uppercase tracking-wide truncate") do
          config[:state_label]
        end
        span(class: "text-[10px] font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wider shrink-0") do
          config[:list_label]
        end
      end
      config[:items].each do |stable_id, value|
        cap_data = config[:caps][stable_id]
        next unless cap_data

        div(class: "flex items-center justify-between py-0.5") do
          span(class: "text-sm text-gray-700 dark:text-gray-300 truncate") do
            cap_data[:capability].name
          end
          span(class: "text-sm font-bold tabular-nums shrink-0 ml-2 #{contribution_color(value)}") do
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
      "text-green-600 dark:text-green-400"
    elsif value > -0.5
      "text-gray-500 dark:text-gray-400"
    elsif value > -1.5
      "text-amber-600 dark:text-amber-400"
    else
      "text-red-600 dark:text-red-400"
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

  def promotion_readiness_visible?
    readiness = primary_scoring[:promotion_readiness]
    return false unless readiness

    readiness[:eligible] || (readiness[:blocked_at_next_level] || []).any?
  end

  def promotion_pill
    readiness = primary_scoring[:promotion_readiness]
    return unless readiness

    if readiness[:eligible]
      span(class: "text-xs font-medium px-2 py-1 rounded-md " \
                  "bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400 " \
                  "border border-green-200 dark:border-green-800") do
        "Eligible for promotion to L#{@person_level + 1}"
      end
    else
      blocked = readiness[:blocked_at_next_level] || []
      if blocked.any?
        span(class: "text-xs text-gray-500 dark:text-gray-400") do
          "Blocked by #{blocked.size} #{'capability'.pluralize(blocked.size)} at L#{@person_level + 1}"
        end
      end
    end
  end

  def continue_assessing_cta(target)
    stable_id = target[:capability].stable_id
    # data-controller="continue-assessing" wires a click handler that
    # dispatches a window event — the matrix controller lives in a
    # different turbo-frame and can't be reached by a `click->matrix#`
    # action from this scope.
    a(
      href: "#cell-#{stable_id}-#{@person_level}",
      class: "inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-medium " \
             "bg-gray-900 dark:bg-white text-white dark:text-gray-900 " \
             "hover:bg-gray-800 dark:hover:bg-gray-100 transition-colors",
      data: {
        controller: "continue-assessing",
        action: "click->continue-assessing#focus",
        continue_assessing_capability_stable_id_value: stable_id,
        continue_assessing_level_ordinal_value: @person_level
      }
    ) do
      plain "Continue"
      span { "→" }
    end
  end

  # ── Verdict helpers ──

  def verdict_headline
    ratio = primary_scoring[:performance_ratio] || 0.0
    if primary_scoring[:mastering]
      "#{subject} exceeding expectations."
    elsif primary_scoring[:meeting_expectations]
      "#{subject} tracking on target."
    elsif ratio >= 0.8
      "#{subject} almost there — close to meeting expectations."
    else
      "Below expectations — focus areas highlighted below."
    end
  end

  def verdict_gloss
    ratio = primary_scoring[:performance_ratio] || 0.0
    pct = (ratio * 100).round(0)
    level_code = @merged_levels.find { |l| l[:ordinal] == @person_level }&.dig(:level_code) || "L#{@person_level}"
    "Baseline coverage at #{pct}% of #{level_code} expectations."
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

  def primary_scoring
    @primary_scoring ||=
      case @context
      when :self      then @self_scoring || @scoring
      when :manager   then @manager_scoring || @scoring
      when :alignment then @aligned_scoring || @scoring
      else @scoring
      end
  end

  def performance_color(ratio)
    if ratio >= @mastery_threshold
      "text-purple-600 dark:text-purple-400"
    elsif ratio >= @meeting_expectation_threshold
      "text-green-600 dark:text-green-400"
    elsif ratio >= 0.8
      "text-amber-600 dark:text-amber-400"
    else
      "text-red-600 dark:text-red-400"
    end
  end

  def performance_bar_color(ratio)
    if ratio >= @mastery_threshold
      "bg-purple-500"
    elsif ratio >= @meeting_expectation_threshold
      "bg-green-500"
    elsif ratio >= 0.8
      "bg-amber-500"
    else
      "bg-red-500"
    end
  end
end
