# frozen_string_literal: true

# One field in an HRIS's catalogue, offered to an admin by name.
#
# A list field's values have ids of their own, so a unit read from one keeps
# its identity through a rename; a text field has only its text.
#
# @!attribute [r] id
#   @return [String] the field's path, as the provider's people API takes it
# @!attribute [r] name
#   @return [String]
# @!attribute [r] kind
#   @return [Symbol] :list or :text
# @!attribute [r] values
#   @return [Array<Hris::Field::Value>] a list field's values; empty for text
class Hris::Field < Data.define(:id, :name, :kind, :values)
  # One value of a list field.
  #
  # @!attribute [r] id
  #   @return [String]
  # @!attribute [r] name
  #   @return [String]
  Value = Data.define(:id, :name)

  KINDS = %i[list text].freeze

  # @param id [String]
  # @param name [String]
  # @param kind [Symbol] :list or :text
  # @param values [Array<Hris::Field::Value>]
  def initialize(id:, name:, kind:, values: [])
    raise ArgumentError, "unknown field kind: #{kind.inspect}" unless KINDS.include?(kind)

    super(id:, name:, kind:, values: values.freeze)
  end

  # @return [Boolean]
  def list? = kind == :list

  # @return [Boolean]
  def text? = kind == :text
end
