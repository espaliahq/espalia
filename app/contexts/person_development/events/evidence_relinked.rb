# frozen_string_literal: true

# Event emitted when an existing evidence item is moved to a different
# (capability, level) coordinate.
#
# The original link is preserved by event history — replay tells the full
# story of where the evidence has been. The projection updates the
# {EvidenceItem} read model in place; queries against the read model see
# the current location only.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID of the evidence item being moved
#   @option data [String] :previous_capability_stable_id where it was
#   @option data [Integer] :previous_level_ordinal where it was
#   @option data [String] :new_capability_stable_id where it's going
#   @option data [Integer] :new_level_ordinal where it's going
#   @option data [String] :relinked_by_id UUID of the Person making the change
#   @option data [String, nil] :rationale optional explanation of the move
#
class PersonDevelopment::Events::EvidenceRelinked < RubyEventStore::Event
end
