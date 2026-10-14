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

  # The carried-forward flag for the same perspective. Agreed values are never
  # carried, so alignment has none.
  CONTEXT_CARRIED_KEYS = {
    self:    :current_frequency_carried,
    manager: :manager_frequency_carried
  }.freeze

  # Whether a cell's value in the viewer's perspective still asks to be
  # confirmed — carried from the last cycle and not frozen by an alignment.
  #
  # @param cell [Hash, nil] one cell from `MatrixDataBuilder`
  # @param context [Symbol]
  # @return [Boolean]
  def self.to_confirm?(cell, context)
    key = CONTEXT_CARRIED_KEYS[context]
    key.present? && cell.present? && cell[key].present? && cell[:frozen_by].nil?
  end

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
end
