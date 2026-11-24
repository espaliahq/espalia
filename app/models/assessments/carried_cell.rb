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

  # Whether a side's carried value still waits to be confirmed: seeded, on a
  # cell nobody has agreed. Agreeing a cell confirms both sides, so readers
  # that pluck columns ask here; the SQL twin is
  # {AssessmentLevelRating::SELF_VETTED_SQL}.
  #
  # @param source [String, nil] the side's `*_rating_source`
  # @param aligned_frequency [String, nil] the cell's agreed value
  # @return [Boolean]
  def unconfirmed?(source, aligned_frequency)
    source == "seeded" && aligned_frequency.nil?
  end

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
