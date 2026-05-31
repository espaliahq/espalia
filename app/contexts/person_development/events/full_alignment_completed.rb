# frozen_string_literal: true

# Event emitted when alignment is marked complete for an assessment cycle.
#
# Once this event lands, ALL ratings are frozen for the cycle — including
# the agreed values themselves. The aligned values become the authoritative
# performance record for the cycle. Issued only by the assessee's current
# direct manager via the AlignmentCompletionsController.
#
# Snapshot point — long person-development streams compress here.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle being completed
#   @option data [String] :completed_by_id UUID of the person who completed alignment
#   @option data [Integer, nil] :framework_version the framework version this cycle
#     was assessed against at completion (the join version, advanced by any
#     mid-cycle migration). Captured so reporting can attribute a completed
#     assessment to its version without replaying the stream. nil on historical
#     events emitted before this was added.
#
class PersonDevelopment::Events::FullAlignmentCompleted < RubyEventStore::Event
end
