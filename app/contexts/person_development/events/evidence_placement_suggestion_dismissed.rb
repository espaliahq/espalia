# frozen_string_literal: true

# A person dismissed a pending suggestion. The model never proposes that cell
# for the evidence item again.
#
# The reason is free text, stored unencrypted and permanently, as comments are
# ([#539](https://github.com/espaliahq/espalia/issues/539), decided 2026-11-23).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id
#   @option data [String] :evidence_id
#   @option data [String, nil] :dismissed_by_id person_id of who dismissed it, nil when unknown
#   @option data [String, nil] :reason why, in their words
#   @option data [String] :dismissed_at ISO 8601 time of the dismissal
#   @option data [Boolean] :already_held true when recorded from a dismissal made before suggestions were events
#
class PersonDevelopment::Events::EvidencePlacementSuggestionDismissed < RubyEventStore::Event
end
