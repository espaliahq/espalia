# frozen_string_literal: true

# Event emitted on a PersonDev stream when a person joins an assessment cycle.
#
# Written by the cross-stream sync handler
# ({AssessmentCycles::SyncHandlers::PersonEnrollmentSync}) in response to
# {AssessmentCycles::Events::PersonEnrolled}. Keeps the PersonDev stream
# self-contained so replay tells the full story.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle being joined
#   @option data [Integer] :framework_version version of the framework this cycle assesses against
#
class PersonDevelopment::Events::JoinedAssessmentCycle < RubyEventStore::Event
end
