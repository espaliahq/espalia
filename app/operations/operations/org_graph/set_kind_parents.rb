# frozen_string_literal: true

# States which unit types a unit type Espalia holds can sit under, and
# whether it can sit at the top.
class Operations::OrgGraph::SetKindParents < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Set which unit types a unit type can sit under (parent_ids, other level_ids in the taxonomy; " \
              "list the type itself to let it nest) and whether it can sit at the top, from effective_on " \
              "(today by default). parent_ids replaces the whole list. A type needs somewhere to sit: a " \
              "parent other than itself, or the top. Refused, naming them, while live units would no longer " \
              "fit; refused for a type an HRIS provides, and for a date before the types last changed. " \
              "Refused unless the caller is a tenant admin."
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :parent_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "level_ids this type can sit under" }
  parameter :top, :boolean, required: true

  # @return [Hash] `{ level_id, name, parent_ids, top, effective_on, levels }`, levels top first
  def perform
    level_id = params[:level_id].to_s.downcase
    level = current_levels.find { |candidate| candidate.id == level_id }
    if level && level.provider != ::OrgGraph::StructureAggregate::ESPALIA
      raise Operations::Base::ParameterError,
            "#{level.name} comes from #{HrisConfig.provider_label(level.provider)}, so its rules follow it"
    end

    parent_ids = Array(params[:parent_ids]).map { |id| id.to_s.downcase }
    refusing_as_parameter_errors do
      structure_handler.set_kind_parents(level_id, parent_ids:, top: params[:top], effective_on:)
    end
    { level_id:, name: level&.name, parent_ids:, top: params[:top], effective_on:, levels: levels_payload }
  end
end
