# frozen_string_literal: true

# Event emitted when an evidence link's valence is reclassified — e.g.
# what was recorded as "demonstrated" is re-judged a "growth_area", or a
# pre-valence link (nil) is classified for the first time.
#
# Reclassification is deliberately its own event rather than a
# remove-link + add-link pair: the link's identity and `linked_at`
# history are preserved, and the activity feed tells the true story
# ("reclassified", not "unlinked then relinked").
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID of the evidence item
#   @option data [String] :capability_stable_id the link's capability
#   @option data [Integer] :level_ordinal the link's level
#   @option data [String, nil] :previous_valence what it was (nil for a
#     pre-valence link classified for the first time)
#   @option data [String] :valence the new value — one of EvidenceLink::VALENCES
#   @option data [String] :changed_by_id UUID of the Person reclassifying
#
class PersonDevelopment::Events::EvidenceLinkRevalenced < RubyEventStore::Event
end
