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
#   state, or five or more points apart) AND clear the same coverage gate
#   against their own ratings.
class Views::Assessments::CategoryIndicators < Views::Base
  include Views::Assessments::Concerns::RatedCount
  include Views::Assessments::Concerns::ScoreScale
  include Views::Assessments::Concerns::DefinedTerms

  COVERAGE_UNLOCK_THRESHOLD = Views::Assessments::HeroSummary::COVERAGE_UNLOCK_THRESHOLD

  # @param category_id [String]
  # @param category_score [Hash, nil] the primary perspective's
  #   `category_scores[id]` — components plus `:state`
  # @param secondary_scores [Array<Hash>] `{ label:, context:, score: }`
  #   from {Assessments::SecondaryPerspectives} — each carries its own
  #   context so its coverage can be judged on its own ratings
  # @param category_data [Hash, nil] entry from `matrix_data[:categories]`
  # @param context [Symbol] :self, :manager, or :alignment
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param thresholds [Hash] the framework's own bands, for the definitions
  # @param viewer_is_manager [Boolean] whether the reader is the
  #   manager-side party — the definitions address them accordingly
  # @param confirm_href [String, nil] where to confirm this category's carried
  #   ratings in bulk; nil hides the link (a viewer who can't rate, a lens)
  def initialize(category_id:, category_score:, category_data:, merged_levels:, person_level:,
                 secondary_scores: [], context: :self, thresholds: {}, viewer_is_manager: false,
                 confirm_href: nil)
    @category_id = category_id
    @confirm_href = confirm_href
    @category_score = category_score
    @secondary_scores = secondary_scores
    @category_data = category_data
    @context = context
    @merged_levels = merged_levels
    @person_level = person_level
    @viewer_is_manager = viewer_is_manager
    @underperforming_threshold = thresholds[:underperforming]
    @meeting_threshold = thresholds[:meeting]
    @mastery_threshold = thresholds[:mastering]
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
      confirm_link
    end
  end

  # Where a category's carried ratings are confirmed in bulk, or nil when the
  # viewer has none to confirm here: a started alignment or no rating
  # authority (both `frozen`), or a lens, which confirms through its pills.
  # The one gate, shared by the page and the rating responses.
  #
  # @return [String, nil]
  def self.confirm_href(assessment_id:, category_id:, context:, frozen:, home:)
    return if frozen || !home || !Assessments::CarriedCell::CARRIED_KEYS.key?(context)

    Rails.application.routes.url_helpers.assessment_carried_ratings_path(assessment_id, category_id: category_id)
  end

  private

  # Re-rendered with the cluster after every rating, so the count stays true
  # as cells are confirmed one by one (#480).
  def confirm_link
    return unless @confirm_href

    count = carried_count
    return unless count.positive?

    a(href: @confirm_href, data: { turbo_frame: "_top" },
      class: "#{Components::Shared::ToConfirmChip::COMPACT_CLASSES} min-h-6 gap-1 hover:bg-warning-subtle") do
      plain "Confirm #{count} carried"
      span(aria: { hidden: "true" }) { "→" }
    end
  end

  # The current level only — the same work the status pill and hero count,
  # so the numbers on one page agree.
  def carried_count
    Assessments::CarriedCell.at_level(@category_data[:capabilities], @person_level, @context).size
  end

  def counts
    @counts ||= @category_data ? category_rated_count(@category_data, @context) : { rated: 0, total: 0 }
  end

  def unlock_target
    (counts[:total] * COVERAGE_UNLOCK_THRESHOLD).ceil
  end

  def unlocked?
    unlocked_for?(@context, @category_score)
  end

  # The coverage rule against one perspective's own ratings.
  def unlocked_for?(context, score)
    return false unless score && score[:scorable]

    perspective_counts = context == @context ? counts : category_rated_count(@category_data, context)
    return true if perspective_counts[:total].zero?

    perspective_counts[:rated] >= (perspective_counts[:total] * COVERAGE_UNLOCK_THRESHOLD).ceil
  end

  # "3/24 rated" — quiet text count so in-progress assessments show what's
  # still untouched.
  def rated_count_badge
    return if counts[:total].zero?

    defined_term(
      :rated_count, label: "#{counts[:rated]}/#{counts[:total]} rated", suffix: @category_id,
      trigger_class: "text-[11px] text-muted tabular-nums whitespace-nowrap"
    )
  end

  def unlock_hint
    return unless @category_score && counts[:total].positive?

    span(class: "text-[11px] text-muted whitespace-nowrap") do
      "score unlocks at #{unlock_target}"
    end
  end

  def score_summary
    state = @category_score[:state]
    if (split = split_text(@category_score))
      span(class: "hidden sm:inline text-[11px] text-muted tabular-nums whitespace-nowrap") do
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
  # "Self: 45%", coloured by its state — with the shared amber divergence
  # dot. Each is held to the coverage gate against ITS OWN ratings: a
  # manager who has rated every cell should not see "Self: 0%" and read it
  # as a verdict when the assessee simply has not started.
  def divergent_annotations
    @secondary_scores.each do |entry|
      alt = entry[:score]
      next unless alt && unlocked_for?(entry[:context], alt) && divergent?(alt)

      span(class: "flex items-center gap-1") do
        span(class: "w-1.5 h-1.5 rounded-full bg-warning-strong shrink-0") { }
        span(class: "text-[10px] text-muted") { "#{entry[:label]}:" }
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
