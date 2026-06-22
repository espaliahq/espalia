# frozen_string_literal: true

# Event emitted when a completed alignment is re-opened for an assessment cycle.
#
# Reverses a {FullAlignmentCompleted} so a manager can correct a cycle that was
# marked complete by accident. The cycle returns to the `aligning` phase: the
# agreed (aligned) per-cell values are PRESERVED — the manager resumes the
# conversation exactly where it was left and re-completes when ready. Issued
# only by the assessee's current direct manager, and only while the cycle is
# still open (enforced by the controller-side {AssessmentPolicy#reopen_alignment?}).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle alignment is re-opening on
#   @option data [String] :reopened_by_id UUID of the person who re-opened alignment
#
class PersonDevelopment::Events::AlignmentReopened < RubyEventStore::Event
end
