# frozen_string_literal: true

# Shared rated/total cell counts per category.
#
# Includes-mixin for any Phlex view that has a `categories` array of the
# shape `MatrixDataBuilder` returns (each `cat[:capabilities][n][:cells]`
# is keyed by ordinal). The frequency key the count is computed against
# follows the current `:self` / `:manager` / `:alignment` context so the
# count reflects what the viewer is actually rating.
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
    rated = 0
    total = 0
    category_data[:capabilities].each do |cap|
      cap[:cells].each_value do |cell|
        total += 1
        rated += 1 if cell[freq_key].present?
      end
    end
    { rated: rated, total: total }
  end
end
