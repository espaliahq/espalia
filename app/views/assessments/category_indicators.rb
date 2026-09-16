# frozen_string_literal: true

# A category's score at the head of its section — the same scale and
# vocabulary as the hero, one altitude down: the number (coloured by its
# state — no state word, a quick indicator has no room for one), the split
# when it adds something ("100% · +50% toward E4"), the bar, and the rated
# count.
#
# Renders as a single Turbo Stream target (`category-indicators-<id>`) so
# everything updates atomically when a rating changes the scoring
# perspective. The rating controllers render this same view.
#
# Honesty guards, both the hero's own rules:
# - **Coverage gate.** Until at least half of the category's assessed-level
#   cells carry the viewer's rating, no score shows — "1/4 rated · score
#   unlocks at 2" instead of a misleadingly low number.
# - **Secondary perspectives** appear only when they diverge (a different
#   state, or five or more points apart).
class Views::Assessments::CategoryIndicators < Views::Base
  include Views::Assessments::Concerns::RatedCount
  include Views::Assessments::Concerns::ScoreScale

  # @param category_id [String]
  # @param category_score [Hash, nil] the primary perspective's
  #   `category_scores[id]` — components plus `:state`
  # @param secondary_scores [Array<Array(String, Hash)>] [["Mgr", {…}], …]
  # @param category_data [Hash, nil] entry from `matrix_data[:categories]`
  # @param context [Symbol] :self, :manager, or :alignment
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  def initialize(category_id:, category_score:, category_data:, merged_levels:, person_level:,
                 secondary_scores: [], context: :self)
    @category_id = category_id
    @category_score = category_score
    @secondary_scores = secondary_scores
    @category_data = category_data
    @context = context
    @merged_levels = merged_levels
    @person_level = person_level
  end

  def view_template
    span(id: "category-indicators-#{@category_id}", class: "flex flex-col items-end gap-0.5 shrink-0") do
      span(class: "flex items-center gap-2") do
        rated_count_badge
        if unlocked?
          score_summary
        else
          unlock_hint
        end
      end
      divergent_annotations if unlocked?
    end
  end

  private

  def counts
    @counts ||= @category_data ? category_rated_count(@category_data, @context) : { rated: 0, total: 0 }
  end

  def unlock_target
    (counts[:total] * Views::Assessments::HeroSummary::COVERAGE_UNLOCK_THRESHOLD).ceil
  end

  def unlocked?
    return false unless @category_score && @category_score[:scorable]
    return true if counts[:total].zero?

    counts[:rated] >= unlock_target
  end

  # "3/24 rated" — quiet text count so in-progress assessments show what's
  # still untouched.
  def rated_count_badge
    return if counts[:total].zero?

    span(class: "text-[11px] text-gray-600 dark:text-gray-300 tabular-nums whitespace-nowrap") do
      "#{counts[:rated]}/#{counts[:total]} rated"
    end
  end

  def unlock_hint
    return unless @category_score && counts[:total].positive?

    span(class: "text-[11px] text-gray-600 dark:text-gray-300 whitespace-nowrap") do
      "score unlocks at #{unlock_target}"
    end
  end

  def score_summary
    state = @category_score[:state]
    if (split = split_text(@category_score))
      span(class: "hidden sm:inline text-[11px] text-gray-600 dark:text-gray-300 tabular-nums whitespace-nowrap") do
        split
      end
    end
    span(class: "text-sm font-bold tabular-nums #{tone_text(state)}",
         title: state_label(state), data: { category_score: "true", category_state: state }) do
      "#{percent(@category_score[:score])}%"
    end
    render Views::Assessments::ScoreBar.new(
      score: @category_score[:score], state: state, components: @category_score,
      merged_levels: @merged_levels, person_level: @person_level, size: :md
    )
  end

  # The parts, only when they say more than the number does — a "75%"
  # beside a "75%" is noise.
  def split_text(score)
    parts = [ "#{percent(score[:current])}%" ]
    parts << "+#{percent(score[:next])}% toward #{next_code}" if next_level? && score[:next].to_f.positive?
    parts << "−#{percent(1.0 - score[:prior].to_f)}% below" if score[:prior].to_f < 1.0
    parts.size > 1 ? parts.join(" · ") : nil
  end

  # Compact annotations for each divergent secondary perspective —
  # "Self: 45%", coloured by its state — with the shared amber divergence dot.
  def divergent_annotations
    @secondary_scores.each do |label, alt|
      next unless alt && divergent?(alt)

      span(class: "flex items-center gap-1") do
        span(class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0") { }
        span(class: "text-[10px] text-gray-600 dark:text-gray-300") { "#{label}:" }
        span(class: "text-[10px] font-mono tabular-nums #{tone_text(alt[:state])}",
             title: state_label(alt[:state])) { "#{percent(alt[:score])}%" }
      end
    end
  end

  def divergent?(alt)
    alt[:state] != @category_score[:state] ||
      (percent(alt[:score]) - percent(@category_score[:score])).abs >= 5
  end
end
