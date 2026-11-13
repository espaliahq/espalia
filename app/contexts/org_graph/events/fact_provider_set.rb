# frozen_string_literal: true

# A kind of person fact changed provider: who supplies it from now on.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :fact one of {OrgGraph::StructureAggregate::FACTS}
#   @option data [String] :provider "espalia" or an HRIS
#   @option data [String] :previous_provider the provider it replaced; "espalia" until one is set
#   @option data [String] :effective_on ISO 8601 date the setting took effect
#   @option data [String, nil] :set_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::FactProviderSet < RubyEventStore::Event
end
