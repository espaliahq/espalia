# frozen_string_literal: true

# Puts the tenant's taxonomy levels in a new order, top first.
class Operations::OrgGraph::ReorderLevels < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Change the order of the Org Graph's taxonomy levels, from effective_on (today by default). " \
              "level_ids lists every level once, top first. A level an HRIS provides keeps its place, as its " \
              "order comes from the HRIS, and sits above every level Espalia holds. Two levels that both hold " \
              "units keep their order, so no unit ends up above its parent's level. Refused unless the " \
              "caller is a tenant admin."
  approval :in_app

  parameter :level_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "every level_id in the taxonomy, top first" }

  # @return [Hash] `{ level_ids, effective_on, levels }`, levels top first
  def perform
    order = Array(params[:level_ids]).map { |id| id.to_s.downcase }
    levels = current_levels
    levels.each_with_index do |level, index|
      next if level.provider == ::OrgGraph::StructureAggregate::ESPALIA || order[index] == level.id
      next unless order.sort == levels.map(&:id).sort

      raise Operations::Base::ParameterError,
            "#{level.name} comes from #{HrisConfig.provider_label(level.provider)}, so its place is set there"
    end

    refusing_as_parameter_errors { structure_handler.reorder_levels(order, effective_on:) }
    { level_ids: order, effective_on:, levels: levels_payload }
  end
end
