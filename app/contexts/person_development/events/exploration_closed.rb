# frozen_string_literal: true

# Event emitted when a declared exploration (ADR-22) is closed, with what
# came of it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :exploration_id the exploration being closed
#   @option data [String, nil] :closed_by_id UUID of the Person who closed it
#   @option data [String] :outcome "pursue" (work towards it), "not_now"
#     (set aside) or "moved" (the person has moved into the role)
#   @option data [String, nil] :note optional note on the outcome
#
class PersonDevelopment::Events::ExplorationClosed < RubyEventStore::Event
end
