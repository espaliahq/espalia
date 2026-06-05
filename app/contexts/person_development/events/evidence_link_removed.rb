# frozen_string_literal: true

# Event emitted when one of an evidence item's (capability, level) links is
# removed — the item stops appearing in that cell but remains attached to
# its other links.
#
# An active evidence item must always retain at least one link: removing
# the last remaining link is rejected by the aggregate (withdraw the item
# instead, via {EvidenceWithdrawn}). The link row is soft-removed in the
# read model so audit history is preserved.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID of the evidence item
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being unlinked
#   @option data [String] :removed_by_id UUID of the Person removing the link
#   @option data [String, nil] :reason optional explanation of the removal
#
class PersonDevelopment::Events::EvidenceLinkRemoved < RubyEventStore::Event
end
