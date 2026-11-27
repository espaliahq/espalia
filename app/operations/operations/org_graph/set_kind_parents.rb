# frozen_string_literal: true

# States which unit types a unit type can sit under, and whether it can sit
# at the top.
class Operations::OrgGraph::SetKindParents < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Set which unit types a unit type can sit under (parent_ids, other level_ids in the taxonomy; " \
              "list the type itself to let it nest) and whether it can sit at the top, from effective_on " \
              "(today by default). parent_ids replaces the whole list. A type needs somewhere to sit: a " \
              "parent other than itself, or the top. Refused, naming them, while live units would no longer " \
              "fit, and for a date after today or before the types last changed. A type an HRIS provides " \
              "can sit only at the top, or under one type above it that an HRIS provides. " \
              "structure_unit_id names a unit with a structure of its own, whose types these are. " \
              "The organisation's structure needs a tenant admin or an Org Graph editor; a unit's own structure " \
              "also admits an owner of that unit or a unit above it, and anyone above them in the reporting line."
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :parent_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "level_ids this type can sit under" }
  parameter :top, :boolean, required: true
  parameter :structure_unit_id, String, allow_blank: false,
            schema: { format: "uuid", description: "a unit with a structure of its own, to change its unit types; the organisation's structure by default" }

  # @return [Hash] `{ level_id, name, parent_ids, top, effective_on, levels }`, levels top first
  def perform
    level_id = params[:level_id].to_s.downcase
    level = current_levels.find { |candidate| candidate.id == level_id }
    parent_ids = Array(params[:parent_ids]).map { |id| id.to_s.downcase }
    refusing_as_parameter_errors do
      structure_handler.set_kind_parents(level_id, parent_ids:, top: params[:top], effective_on:, **in_structure)
    end
    { level_id:, name: level&.name, **in_structure, parent_ids: current_levels.map(&:id) & parent_ids, top: params[:top], effective_on:,
      levels: levels_payload }
  end
end
