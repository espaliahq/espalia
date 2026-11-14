# frozen_string_literal: true

# Sets who supplies a structure level that holds no live units (#126), and
# for an HRIS the field its units are read from. A level with live units
# changes hands only through the handover, which compares it first
# (integrations_hris_level_handover) and then matches each unit.
#
# Approval is :in_app, as for the tenant's other Org Graph settings.
class Operations::OrgGraph::SetLevelProvider < Operations::Base
  include Operations::OrgGraph::SourceSupport

  description "Set who supplies an Org Graph structure level from today: \"espalia\", or the connected HRIS " \
              "reading the level's units from field, which an HRIS needs. Only a level with no live units; to move a level that " \
              "holds units, compare and hand it over with integrations_hris_level_handover. Levels an HRIS " \
              "supplies sit above the ones Espalia holds."
  category :write
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :provider, String, required: true, allowed: ::OrgGraph::StructureAggregate::PROVIDERS
  parameter :field, String

  # @raise [Pundit::NotAuthorizedError] unless the caller may change the Org Graph's structure
  def policy_check
    authorize :org_graph, :edit_structure?
  end

  # @return [Hash] the level as it now reads
  # @raise [ParameterError]
  def perform
    level = OrgTaxonomyLevel.find_by(id: params[:level_id].to_s.downcase) or
      raise ParameterError, "level_id: no structure level has that id"
    provider = require_provider!(params[:provider])
    if provider != ::OrgGraph::StructureAggregate::ESPALIA && params[:field].blank?
      raise ParameterError, "field: name the HRIS field this level's units are read from"
    end
    refusals do
      structure.set_level_provider(level.id, provider, field: params[:field], effective_on: Date.current)
    end
    level.reload
    { id: level.id, name: level.name, provider: level.provider, field: level.provider_field }
  end
end
