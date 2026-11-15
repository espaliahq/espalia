# frozen_string_literal: true

# A scenario split in two, so part of it can be approved. The agreed part is
# a new scenario in the original's place: same parent, relation and period.
# The original keeps its id, the rest of its changes and every descendant,
# and now sits `on` the agreed part. Every scenario resolves as it did.
#
# Every entry of the original's log for a moved subject and facet goes
# across, undone ones included, so undo and redo behave as before.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id the original, which keeps the rest
#   @option data [String] :agreed_id UUID minted by the caller for the agreed part
#   @option data [Shreddable::Value] :name the agreed part's, under the plan's key
#   @option data [Array<Array(String, String)>] :keys the subject and facet of each change that moved
#   @option data [Array<String>] :moved_event_ids every log entry that moved, in log order
#   @option data [String] :split_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioSplit < RubyEventStore::Event
  extend Shreddable
  shreddable :name, by: :plan
end
