# frozen_string_literal: true

# Event emitted when an alignment rating is cleared for a capability
# at a specific level. Symmetric counterpart to {AssessmentAligned} —
# allows the assessee or manager to undo an alignment value during the
# alignment phase.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being cleared
#   @option data [String] :cycle_id UUID of the cycle this alignment belongs to
#   @option data [String, nil] :cleared_by_id UUID of the Person (assessee or
#     manager) who cleared the alignment. nil on historical events emitted
#     before attribution was added.
#
class PersonDevelopment::Events::AlignmentCleared < RubyEventStore::Event
end
