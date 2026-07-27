# frozen_string_literal: true

# Event emitted on a PersonDev stream when the person's current assessment
# cycle concludes (the cycle is closed with them still enrolled).
#
# Distinct from {PersonDevelopment::Events::LeftAssessmentCycle}: leaving is
# a person-scoped removal (opted out, left the company, enrolled by mistake),
# whereas conclusion is the cycle ending *around* the participant — their
# participation stands as part of the cycle's historical cohort. An unrated
# enrollment still concludes; the event says nothing about how far they got
# (that lives on the progress read model).
#
# Written by the cross-stream sync handler
# ({AssessmentCycles::SyncHandlers::PersonEnrollmentSync}) in response to
# {AssessmentCycles::Events::CycleClosed} — never by controllers.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle that concluded
#
class PersonDevelopment::Events::AssessmentCycleConcluded < RubyEventStore::Event
end
