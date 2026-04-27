# frozen_string_literal: true

# Event emitted when alignment is formally opened for an assessment cycle.
#
# Once this event lands, self and manager ratings are frozen for the cycle —
# the assessment becomes a shared conversation about agreed values, not
# individual editing. Issued only by the assessee's current direct manager
# via the AlignmentStartsController.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle alignment is starting on
#   @option data [String] :started_by_id UUID of the person who started alignment
#
class PersonDevelopment::Events::AlignmentStarted < RubyEventStore::Event
end
