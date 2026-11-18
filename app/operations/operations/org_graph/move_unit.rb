# frozen_string_literal: true

# Moves a unit Espalia holds beneath another unit, or to the top.
class Operations::OrgGraph::MoveUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite
  prepend Operations::OrgGraph::PlanWrite

  description "Move a unit in the Org Graph beneath another live unit of a kind its own kind can sit " \
              "under, or to the top when parent_id is omitted and its kind can sit there, from effective_on (today by default). Only a unit Espalia holds " \
              "can be moved here. Moving a unit changes who inherits its ownership, so the caller needs " \
              "rights on the unit and where it lands. To move a unit from the top structure into a unit's own " \
              "structure, pass conversion, a type of that structure for each type the unit and those beneath it " \
              "hold; each changes type in the same change. That needs a tenant admin, and is one-way until a unit " \
              "can move out of a structure; withdrawing the structure converts its units back, where they stay."
  approval :in_app

  CONVERSION_SCHEMA = {
    type: "object", additionalProperties: { type: "string", format: "uuid" },
    description: "each level_id the unit or a unit beneath it holds => the level_id it becomes, a type of the " \
                 "structure it moves into"
  }.freeze

  parameter :unit_id, String, required: true
  parameter :parent_id, String, allow_blank: false
  parameter :conversion, Hash, schema: CONVERSION_SCHEMA

  # @return [Hash] `{ unit_id, parent_id, effective_on }`, and the conversion when given, as level_id => level_id
  def perform
    unit = live_unit!(:unit_id)
    parent = params[:parent_id] && live_unit!(:parent_id)

    move = -> { structure_handler.move_unit(unit.id, parent&.id, effective_on:, **conversion_option, **plan) }
    conversion_option.empty? ? move.call : refusing_as_parameter_errors(&move)
    { unit_id: unit.id, parent_id: parent&.id, effective_on: effective_on, **conversion_option }
  end

  private

  def conversion_option
    return {} if params[:conversion].nil?

    @conversion_option ||= { conversion: params[:conversion].to_h.to_h { |held, becomes| [ held.to_s.downcase, becomes.to_s.downcase ] } }
  end
end
