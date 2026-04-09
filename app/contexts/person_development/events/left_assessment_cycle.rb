# frozen_string_literal: true

# Event emitted on a PersonDev stream when a person leaves an assessment cycle.
#
# Written by the cross-stream sync handler
# ({AssessmentCycles::SyncHandlers::PersonEnrollmentSync}) in response to
# {AssessmentCycles::Events::PersonUnenrolled} or
# {AssessmentCycles::Events::CycleClosed}.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle being left
#   @option data [String] :reason why the person left (e.g. "cycle_closed", "withdrew")
#
class PersonDevelopment::Events::LeftAssessmentCycle < RubyEventStore::Event
end
