# frozen_string_literal: true

# A capability card's name row: the name, the Blocked marker, and the
# capability's own score on the assessment's scale — always with its split
# ("50% · +50% toward E4"), never the net alone, because under the
# multiplicative gate "most of the time" at L with "consistently" at L+1
# nets to 100% next to a pill that says "Most of the time".
#
# Carries `id="capability-name-<stable_id>"` so the rating controllers'
# Turbo Streams replace it in place — they render this same view, so the
# post-rate row cannot drift from the initial one.
#
# A single capability carries no state word: its states are its ratings,
# which the pill already names. The number is coloured by the engine's
# per-capability state (the framework's own thresholds applied to the
# capability's score; blocked → amber), so the card and the hero speak one
# language.
class Views::Assessments::CapabilityNameRow < Views::Base
  include Views::Assessments::Concerns::ScoreScale
  include Views::Assessments::Concerns::DefinedTerms

  # @param capability [FrameworkState::Capability]
  # @param score [Hash, nil] `scoring[:capability_scores][stable_id]`
  # @param rated [Boolean] whether the assessed-level cell carries the
  #   viewer's perspective's rating — an unrated capability shows "Not
  #   rated", never 0%
  # @param blocked [Boolean]
  # @param block_reason [String, nil]
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param thresholds [Hash] the framework's own bands, for the definitions
  def initialize(capability:, score:, rated:, blocked:, block_reason:, merged_levels:, person_level:,
                 thresholds: {})
    @capability = capability
    @score = score
    @rated = rated
    @blocked = blocked
    @block_reason = block_reason
    @merged_levels = merged_levels
    @person_level = person_level
    @underperforming_threshold = thresholds[:underperforming]
    @meeting_threshold = thresholds[:meeting]
    @mastery_threshold = thresholds[:mastering]
  end

  def view_template
    div(id: "capability-name-#{@capability.stable_id}", class: "flex flex-wrap items-center gap-x-2 gap-y-1") do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white") { @capability.name }
      blocked_badge if @blocked
      score_summary
    end
  end

  private

  # The badge defines itself: "Blocked" is the most consequential word on
  # the card and the least self-explanatory. The engine's own reason stays
  # on the `title` for anyone who wants the arithmetic.
  def blocked_badge
    span(title: @block_reason) do
      defined_term(
        :blocked, suffix: @capability.stable_id,
        trigger_class: "text-[10px] font-medium text-red-700 dark:text-red-400 " \
                       "bg-red-50 dark:bg-red-900/20 px-1.5 py-0.5 rounded"
      )
    end
  end

  def score_summary
    div(class: "ml-auto flex items-center gap-2", data: { capability_score: "true" }) do
      if @score.nil? || !@score[:scorable]
        defined_term(:no_expectation, label: "No expectation at #{current_code}",
                     suffix: @capability.stable_id, align: :right, trigger_class: MUTED)
      elsif !@rated
        defined_term(:not_rated, suffix: @capability.stable_id, align: :right, trigger_class: MUTED)
      else
        state = @score[:state]
        if (split = split_text)
          span(class: "text-xs text-gray-600 dark:text-gray-300 tabular-nums hidden sm:inline") { split }
        end
        span(class: "text-base font-bold tabular-nums #{tone_text(state)}", title: state_label(state)) do
          "#{percent(@score[:score])}%"
        end
        render Views::Assessments::ScoreBar.new(
          score: @score[:score], state: state, components: @score,
          merged_levels: @merged_levels, person_level: @person_level, size: :sm
        )
      end
    end
  end

  MUTED = "text-xs text-gray-600 dark:text-gray-300"

  # "100% · +50% toward E4" — the assessed-level share and the next-band
  # credit, so the net never stands alone. A prior-level deficit shows too.
  def split_text
    parts = [ "#{percent(@score[:current])}%" ]
    parts << "+#{percent(@score[:next])}% toward #{next_code}" if next_level? && @score[:next].to_f.positive?
    parts << "−#{percent(1.0 - @score[:prior].to_f)}% below" if @score[:prior].to_f < 1.0
    parts.size > 1 ? parts.join(" · ") : nil
  end
end
