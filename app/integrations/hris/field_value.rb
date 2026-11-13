# frozen_string_literal: true

# What one person's HRIS record holds for one field.
#
# Blank is a field the HRIS sent empty; withheld is a record that leaves the
# field out, so nothing about that person can be read from it.
#
# @!attribute [r] state
#   @return [Symbol] :value, :blank or :withheld
# @!attribute [r] id
#   @return [String, nil] a list item's id; nil for a text field
# @!attribute [r] label
#   @return [String, nil] what the HRIS shows
class Hris::FieldValue < Data.define(:state, :id, :label)
  STATES = %i[value blank withheld].freeze

  # @return [Hris::FieldValue]
  def self.blank = new(state: :blank)

  # @return [Hris::FieldValue]
  def self.withheld = new(state: :withheld)

  # @param state [Symbol] one of {STATES}
  # @param id [String, nil]
  # @param label [String, nil]
  def initialize(state:, id: nil, label: nil)
    raise ArgumentError, "unknown field value state: #{state.inspect}" unless STATES.include?(state)

    super
  end

  # @return [Boolean]
  def value? = state == :value

  # @return [Boolean]
  def blank? = state == :blank

  # @return [Boolean]
  def withheld? = state == :withheld

  # What tells two values apart: a list item's id, else the text itself.
  #
  # @return [String, nil]
  def key = id || label
end
