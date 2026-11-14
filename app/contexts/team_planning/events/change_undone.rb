# frozen_string_literal: true

# A scenario took back one entry of its log: a change, a pin or a clear. From
# then on it resolves as if that entry had not been made, until a
# {TeamPlanning::Events::ChangeRedone} restores it. The entry stays in the
# stream.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :subject_id of the entry it takes back
#   @option data [String] :facet of that entry, the second half of its key
#   @option data [String] :undone_event_id the event id of the change, pin or clear it takes back
#   @option data [String] :undone_by_id person_id of the actor
#   @option data [String, nil] :in_effect_event_id the change or pin then in effect for this subject and facet, nil when none is
#
class TeamPlanning::Events::ChangeUndone < RubyEventStore::Event
end
