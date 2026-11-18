# frozen_string_literal: true

# Gives a unit a structure of its own: unit types that only the units beneath
# it use ([#494](https://github.com/espaliahq/espalia/issues/494)). Every unit
# beneath it changes to the type the conversion names, in the same change.
#
# Types are named, not numbered: a caller can't know the ids before they
# exist, so parent_names and the conversion name types in the new structure,
# and the operation mints their ids.
class Operations::OrgGraph::DeclareStructure < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  LEVELS_SCHEMA = {
    type: "array", minItems: 1,
    items: {
      type: "object", additionalProperties: false, required: [ "name" ],
      properties: {
        name: { type: "string", description: "unique within the structure, ignoring case" },
        parent_names: { type: "array", items: { type: "string" },
                        description: "types in this structure it can sit under; name the type itself to let it nest" },
        top: { type: "boolean", description: "whether it can sit directly under the unit; true by default" },
        copied_from_level_id: { type: "string", format: "uuid",
                                description: "the type it copies, in the structure copied_from names" }
      }
    },
    description: "the structure's unit types, top first"
  }.freeze

  CONVERSION_SCHEMA = {
    type: "object", additionalProperties: { type: "string" },
    description: "each level_id a unit beneath holds => the name of the type in this structure it becomes"
  }.freeze

  description "Give a unit a structure of its own, from effective_on (today by default): unit types only the " \
              "units beneath it use, while the unit itself keeps its type. Every unit beneath it changes type " \
              "in the same change, by conversion, which names a new type for each type held there. copied_from " \
              "is \"top\" or a unit with a structure of its own, when the types copy that structure's. Refused, " \
              "naming them, for units that wouldn't fit, a unit an HRIS supplies beneath it, a unit that already " \
              "has a structure, and a date after today or before a change beneath. " \
              "org_graph_withdraw_structure undoes it. Refused unless the caller is a tenant admin."
  approval :in_app

  parameter :unit_id, String, required: true, schema: { format: "uuid" }
  parameter :levels, Array, required: true, schema: LEVELS_SCHEMA
  parameter :conversion, Hash, schema: CONVERSION_SCHEMA
  parameter :copied_from, String, allow_blank: false

  # @return [Hash] `{ unit_id, name, copied_from, conversion, effective_on, levels }`, conversion
  #   as level_id => level_id, levels top first
  def perform
    ids = level_ids
    conversion = conversion_ids(ids)
    refusing_as_parameter_errors do
      structure_handler.declare_structure(structure_unit.id, levels: declared_levels(ids), conversion:, effective_on:,
                                                             copied_from: params[:copied_from])
    end
    { unit_id: structure_unit.id, name: structure_unit.name, copied_from: params[:copied_from], conversion:, effective_on:,
      levels: levels_payload }
  end

  private

  def structure_unit
    @structure_unit ||= live_unit!(:unit_id)
  end

  # @return [Hash{String => String}] each type's name, as given, => a new id
  def level_ids
    names = params[:levels].map { |level| level.to_h.stringify_keys["name"].to_s.strip }
    raise Operations::Base::ParameterError, "Every unit type needs a name" if names.any?(&:empty?)
    unless names.uniq(&:downcase).size == names.size
      raise Operations::Base::ParameterError, "Each unit type needs its own name"
    end

    names.index_with { SecureRandom.uuid_v7 }
  end

  def declared_levels(ids)
    params[:levels].map do |level|
      level = level.to_h.stringify_keys
      name = level["name"].to_s.strip
      { level_id: ids.fetch(name), name:, copied_from_level_id: level["copied_from_level_id"]&.downcase,
        parent_level_ids: level["parent_names"]&.map { |parent| type_id!(ids, parent, "#{name} names a parent") },
        top: level["top"] }.compact
    end
  end

  def conversion_ids(ids)
    (params[:conversion] || {}).to_h.to_h do |held, becomes|
      [ held.to_s.downcase, type_id!(ids, becomes, "The conversion names a type") ]
    end
  end

  def type_id!(ids, name, what)
    ids.find { |candidate, _| candidate.casecmp?(name.to_s.strip) }&.last or
      raise Operations::Base::ParameterError, "#{what}, #{name.to_s.strip.inspect}, that isn't in the structure"
  end
end
