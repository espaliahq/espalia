# frozen_string_literal: true

# A planner wrote, rewrote or cleared the note on a change or pin that stands
# in its scenario. The note is the planner's reason, never part of the end
# state, so nothing resolves differently. It is not an entry of the log: it
# can't be undone, and the note follows its change through undo and redo.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :subject_id of the change it notes
#   @option data [String] :facet of that change, the second half of its key
#   @option data [String] :noted_event_id the event id of the change or pin
#   @option data [Shreddable::Value, nil] :note sealed under the subject's key, as its change's is; nil clears it
#   @option data [String] :noted_by_id person_id of the actor
#
class TeamPlanning::Events::ChangeNoted < RubyEventStore::Event
  extend Shreddable

  shreddable :note, by: :person, person: TeamPlanning::ChangeKinds::NOTED_PERSON
end
