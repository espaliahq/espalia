# frozen_string_literal: true

# A new run of the model replaced an evidence item's pending suggestions.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id
#   @option data [Array<String>] :suggestion_ids the pending suggestions replaced
#
class PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded < RubyEventStore::Event
end
