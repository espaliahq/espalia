# frozen_string_literal: true

# A change moved to the step before or after its own on the timeline path.
# Every entry of the source's log for that subject and facet goes across,
# undone ones included, as a split moves them, so undo and redo behave as
# before. A departure set to leave in the source leaves in the target.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id the step the change left
#   @option data [String] :to_scenario_id the step it moved to
#   @option data [String] :subject_id
#   @option data [String] :facet "assignment", "position" or "departure"
#   @option data [String] :direction "earlier" or "later"
#   @option data [Array<String>] :moved_event_ids every log entry that moved, in log order
#   @option data [String, nil] :left_before_id the entry that followed them in the step they left, nil for none
#   @option data [String] :moved_by_id person_id of the actor
#
class TeamPlanning::Events::ChangeMoved < RubyEventStore::Event
end
