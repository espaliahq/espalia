# frozen_string_literal: true

# Whether a cell's value, in the viewer's own perspective, still asks to be
# confirmed this cycle: carried from the last cycle and not frozen by a
# started alignment (#480). The one definition behind the status pill, the
# hero, the card chip, the category link and the review page, so they can't
# disagree about the same work.
module Assessments::CarriedCell
  # Agreed values are never carried, so alignment has no key.
  CARRIED_KEYS = {
    self: :current_frequency_carried,
    manager: :manager_frequency_carried
  }.freeze

  module_function

  # @param cell [Hash, nil] one cell from {Assessments::MatrixDataBuilder}
  # @param context [Symbol] :self, :manager or :alignment
  # @return [Boolean]
  def to_confirm?(cell, context)
    key = CARRIED_KEYS[context]
    key.present? && cell.present? && cell[key].present? && cell[:frozen_by].nil?
  end

  # The capabilities whose cell at the level still asks — the work that
  # stands between the viewer and a complete assessment.
  #
  # @param capabilities [Array<Hash>] capability data from the builder
  # @param level_ordinal [Integer]
  # @param context [Symbol]
  # @return [Array<Hash>]
  def at_level(capabilities, level_ordinal, context)
    capabilities.select { |cap| to_confirm?(cap[:cells][level_ordinal], context) }
  end
end
