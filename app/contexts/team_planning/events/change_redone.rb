# frozen_string_literal: true

# A scenario restored an entry of its log it had undone, in its place.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :subject_id of the entry it restores
#   @option data [String] :facet of that entry, the second half of its key
#   @option data [String] :redone_event_id the event id of the change, pin or clear it restores
#   @option data [String] :redone_by_id person_id of the actor
#   @option data [String, nil] :in_effect_event_id the change or pin then in effect for this subject and facet, nil when none is
#
class TeamPlanning::Events::ChangeRedone < RubyEventStore::Event
end
