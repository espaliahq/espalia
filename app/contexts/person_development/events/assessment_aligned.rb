# frozen_string_literal: true

# Event emitted when a manager and person agree on an assessment for a capability at a level.
#
# The aligned_frequency becomes the authoritative rating used in scoring.
# The agreed level for a capability is derived as the highest level_ordinal
# where aligned_frequency == "consistent".
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being agreed upon
#   @option data [String] :aligned_frequency agreed frequency: "some", "occasional", or "consistent"
#   @option data [String] :cycle_id UUID of the cycle this alignment belongs to
#   @option data [String] :comment optional comment on the agreement
#   @option data [String, nil] :aligned_by_id UUID of the Person who recorded the
#     agreement. For manual alignments this is whoever submitted it (assessee or
#     manager); for the auto-aligned cells emitted at alignment start it is the
#     manager who started alignment. nil on historical events emitted before
#     attribution was added.
#
class PersonDevelopment::Events::AssessmentAligned < RubyEventStore::Event
end
