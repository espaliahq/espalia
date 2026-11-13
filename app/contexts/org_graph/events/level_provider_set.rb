# frozen_string_literal: true

# A taxonomy level's provider changed: who supplies its units from now on.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :level_id the taxonomy level
#   @option data [String] :provider "espalia" or an HRIS
#   @option data [String] :previous_provider the provider it replaced; "espalia" until one is set
#   @option data [String] :effective_on ISO 8601 date the setting took effect
#   @option data [String, nil] :set_by_id person_id of the actor
#
class OrgGraph::Events::LevelProviderSet < RubyEventStore::Event
end
