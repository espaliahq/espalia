# frozen_string_literal: true

# Sets who supplies one kind of person fact (#126), and for an HRIS the
# fields it reads the fact's mappable parts from.
#
# Approval is :in_app: it changes where the tenant's people data comes from,
# and from the next sync the HRIS overwrites what Espalia held.
class Operations::OrgGraph::SetFactProvider < Operations::Base
  include Operations::OrgGraph::SourceSupport

  FACTS = ::OrgGraph::StructureAggregate::FACTS
  MAPPABLE = ::OrgGraph::StructureAggregate::MAPPABLE_FIELDS
  FIELDS_SCHEMA = {
    type: "object",
    properties: MAPPABLE.values.flatten.uniq.index_with { { type: "string" } },
    additionalProperties: false
  }.freeze

  description "Set who supplies one kind of person fact from today: \"espalia\", or the connected HRIS. " \
              "Facts: #{FACTS.join(', ')}. For an HRIS, fields names the HRIS field to read a part from " \
              "(#{MAPPABLE.map { |fact, parts| "#{fact}: #{parts.join(', ')}" }.join('; ')}); leave it out to " \
              "keep the fields already chosen. Moving a fact to another provider clears its fields. " \
              "Writes nothing when nothing changes."
  category :write
  approval :in_app

  parameter :fact, String, required: true, allowed: FACTS
  parameter :provider, String, required: true, allowed: ::OrgGraph::StructureAggregate::PROVIDERS
  parameter :fields, Hash, schema: FIELDS_SCHEMA

  # @raise [Pundit::NotAuthorizedError] unless the caller may change the Org Graph's structure
  def policy_check
    authorize :org_graph, :edit_structure?
  end

  # @return [Hash] the fact as it now reads
  # @raise [ParameterError]
  def perform
    provider = require_provider!(params[:provider])
    refusals do
      structure.set_fact_provider(params[:fact], provider, fields: params[:fields], effective_on: Date.current)
    end
    row = OrgFactProvider.find_by(fact: params[:fact])
    { fact: params[:fact], provider: row&.provider || ::OrgGraph::StructureAggregate::ESPALIA, fields: row&.fields || {} }
  end
end
