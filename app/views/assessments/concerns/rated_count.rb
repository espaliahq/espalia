# frozen_string_literal: true

# Shared rated/total cell counts per category.
#
# Includes-mixin for any Phlex view that has a `categories` array of the
# shape `MatrixDataBuilder` returns (each `cat[:capabilities][n][:cells]`
# is keyed by ordinal). The frequency key the count is computed against
# follows the current `:self` / `:manager` / `:alignment` context so the
# count reflects what the viewer is actually rating.
#
# The count reflects only the cell at the person's **current level**
# (`category_data[:person_level]`) — one cell per capability, matching the
# hero coverage gate and the "Assessment Complete" pill. Counting every
# level's cell would inflate the total far beyond the capabilities the
# viewer is actually being asked to rate.
#
module Views::Assessments::Concerns::RatedCount
  CONTEXT_FREQUENCY_KEYS = {
    self:      :current_frequency,
    manager:   :manager_frequency,
    alignment: :aligned_frequency
  }.freeze

  # @param category_data [Hash] one entry from `matrix_data[:categories]`
  # @param context [Symbol] :self, :manager, or :alignment
  # @return [Hash{Symbol => Integer}] { rated:, total: }
  def category_rated_count(category_data, context)
    freq_key = CONTEXT_FREQUENCY_KEYS[context] || :current_frequency
    person_level = category_data[:person_level]
    rated = 0
    total = 0
    category_data[:capabilities].each do |cap|
      cell = cap[:cells][person_level]
      next unless cell

      total += 1
      rated += 1 if cell[freq_key].present?
    end
    { rated: rated, total: total }
  end

  # The hero's coverage rule at category grain: a category's score shows
  # once at least half of its assessed-level cells carry a rating (once
  # every one is agreed, while an alignment is still agreeing them). The
  # chip bar and the capability radar's key read it, so they agree with
  # CategoryIndicators#unlocked? on the section header.
  #
  # @param category_data [Hash] one entry from `matrix_data[:categories]`
  # @param scoring [Hash] the perspective being shown
  # @param context [Symbol] :self, :manager, or :alignment
  # @return [Boolean]
  def category_score_unlocked?(category_data, scoring, context)
    result = scoring.dig(:category_scores, category_data[:category]&.category_id)
    return false unless result && result[:scorable]

    counts = category_rated_count(category_data, context)
    return true if counts[:total].zero?

    counts[:rated] >= Views::Assessments::HeroSummary.unlock_target_for(
      counts[:total], awaiting_agreement: category_data[:awaiting_agreement] || false
    )
  end
end
