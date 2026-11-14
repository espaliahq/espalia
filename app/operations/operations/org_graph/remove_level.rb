# frozen_string_literal: true

# Removes a level from the tenant's taxonomy that no unit has ever held.
class Operations::OrgGraph::RemoveLevel < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Remove a level from the Org Graph's taxonomy, from effective_on (today by default). Only a " \
              "level no unit has ever held, retired units included, can go; the refusal names the units. " \
              "A level an HRIS provides is handed back to Espalia first. Refused unless the caller is a " \
              "tenant admin."
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false

  # @return [Hash] `{ level_id, name, effective_on, levels }`, levels top first
  def perform
    level = current_levels.find { |candidate| candidate.id == params[:level_id].to_s.downcase }
    raise Operations::Base::ParameterError, "There is no such level in the taxonomy" unless level
    unless level.provider == ::OrgGraph::StructureAggregate::ESPALIA
      raise Operations::Base::ParameterError,
            "#{level.name} comes from #{HrisConfig.provider_label(level.provider)}; hand it back to Espalia before removing it"
    end

    refusing_as_parameter_errors { structure_handler.remove_level(level.id, effective_on:) }
    { level_id: level.id, name: level.name, effective_on:, levels: levels_payload }
  end
end
