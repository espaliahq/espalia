# frozen_string_literal: true

# A scenario with nothing forked from it left the plan. Its changes stay in
# the stream, and nothing resolves through them. Its id is never reused.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :removed_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioRemoved < RubyEventStore::Event
end
