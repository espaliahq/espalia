# frozen_string_literal: true

# Event emitted when an assessment cycle is completed.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the completed cycle
#
class PersonDevelopment::Events::AssessmentCycleCompleted < RubyEventStore::Event
end
