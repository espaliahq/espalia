# frozen_string_literal: true

# A kind of person fact changed provider: who supplies it from now on.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :fact one of {OrgGraph::StructureAggregate::FACTS}
#   @option data [String] :provider "espalia" or an HRIS
#   @option data [String] :previous_provider the provider it replaced; "espalia" until one is set
#   @option data [Hash{String => String}] :fields the HRIS field path for each part of the
#     fact named in {OrgGraph::StructureAggregate::MAPPABLE_FIELDS}. Absent before 6.4,
#     which reads as none: the adapter's default fields
#   @option data [String] :effective_on ISO 8601 date the setting took effect
#   @option data [String, nil] :set_by_id person_id of the actor
#
class OrgGraph::Events::FactProviderSet < RubyEventStore::Event
end
