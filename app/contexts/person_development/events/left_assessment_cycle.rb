# frozen_string_literal: true

# Event emitted on a PersonDev stream when a person leaves an assessment cycle.
#
# A person-scoped removal: opted out, left the company, enrolled by mistake.
# A cycle ending normally is NOT a leave — that emits
# {PersonDevelopment::Events::AssessmentCycleConcluded} instead (historical
# streams contain LeftAssessmentCycle with reason "cycle_closed" from before
# the two concepts were separated).
#
# Written by the cross-stream sync handler
# ({AssessmentCycles::SyncHandlers::PersonEnrollmentSync}) in response to
# {AssessmentCycles::Events::PersonUnenrolled}.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle being left
#   @option data [String] :reason why the person left (e.g. "withdrew")
#
class PersonDevelopment::Events::LeftAssessmentCycle < RubyEventStore::Event
end
