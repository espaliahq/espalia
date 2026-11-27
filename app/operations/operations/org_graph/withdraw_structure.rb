# frozen_string_literal: true

# Withdraws a unit's own structure, so the structure above it governs the
# units beneath it again ([#494](https://github.com/espaliahq/espalia/issues/494)).
# Each changes to the type the conversion names, in the same change.
class Operations::OrgGraph::WithdrawStructure < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  CONVERSION_SCHEMA = {
    type: "object", additionalProperties: { type: "string", format: "uuid" },
    description: "each level_id a unit beneath holds => the level_id it becomes, a type the structure above " \
                 "holds and Espalia supplies"
  }.freeze

  description "Withdraw a unit's own structure from effective_on (today by default), so the structure above " \
              "it governs the units beneath it again. Every unit beneath it changes type in the same change, " \
              "by conversion. Refused, naming them, for units that wouldn't fit the structure above, and for a " \
              "date after today or before the structure or a unit beneath last changed. " \
              "Refused unless the caller is a tenant admin, an Org Graph editor, an owner of the unit or a unit " \
              "above it, or anyone above them in the reporting line."
  approval :in_app

  parameter :unit_id, String, required: true, schema: { format: "uuid" }
  parameter :conversion, Hash, schema: CONVERSION_SCHEMA

  # @return [Hash] `{ unit_id, name, conversion, effective_on }`, conversion as level_id => level_id
  def perform
    conversion = (params[:conversion] || {}).to_h.to_h { |held, becomes| [ held.to_s.downcase, becomes.to_s.downcase ] }
    refusing_as_parameter_errors do
      structure_handler.withdraw_structure(structure_unit.id, conversion:, effective_on:)
    end
    { unit_id: structure_unit.id, name: structure_unit.name, conversion:, effective_on: }
  end

  private

  def structure_unit
    @structure_unit ||= live_unit!(:unit_id)
  end
end
