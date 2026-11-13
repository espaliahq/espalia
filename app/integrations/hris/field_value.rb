# frozen_string_literal: true

# What one person's HRIS record holds for one field.
#
# Blank is a field the HRIS sent empty; withheld is a record that leaves the
# field out, so nothing about that person can be read from it. Unreadable is a
# value in a shape Espalia does not know; like withheld, it says nothing, so
# it must never end a membership or change a fact.
#
# @!attribute [r] state
#   @return [Symbol] :value, :blank, :withheld or :unreadable
# @!attribute [r] id
#   @return [String, nil] a list item's id; nil for a text field
# @!attribute [r] label
#   @return [String, nil] what the HRIS shows
class Hris::FieldValue < Data.define(:state, :id, :label)
  STATES = %i[value blank withheld unreadable].freeze

  # @return [Hris::FieldValue]
  def self.blank = new(state: :blank)

  # @return [Hris::FieldValue]
  def self.withheld = new(state: :withheld)

  # @return [Hris::FieldValue]
  def self.unreadable = new(state: :unreadable)

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

  # @return [Boolean]
  def unreadable? = state == :unreadable

  # What tells two values apart: a list item's id, else the text itself.
  #
  # @return [String, nil]
  def key = id || label
end
