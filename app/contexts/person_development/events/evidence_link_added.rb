# frozen_string_literal: true

# Event emitted when an existing evidence item is linked to an additional
# (capability, level) coordinate.
#
# Evidence can demonstrate more than one capability × level — one piece of
# feedback often acts as evidence for several expectations. The item's
# first link is established by {EvidenceRecorded}; every subsequent link
# is a separate {EvidenceLinkAdded} event. The item then surfaces in every
# linked cell of the assessment matrix.
#
# Anchored to (capability_stable_id, level_ordinal) — the same coordinate
# system used by ratings and behavioural expectations — so the link stays
# associated with the expectation it's evidence for across role
# transitions and framework versions.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID of the evidence item
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being evidenced
#   @option data [String] :linked_by_id UUID of the Person adding the link
#   @option data [String, nil] :rationale optional explanation of the link
#   @option data [String] :valence the linker's judgment of what the
#     evidence says about the behaviour at this cell — one of
#     EvidenceLink::VALENCES. Required on new events; absent on events
#     published before valence existed (consumers must tolerate nil).
#
class PersonDevelopment::Events::EvidenceLinkAdded < RubyEventStore::Event
end
