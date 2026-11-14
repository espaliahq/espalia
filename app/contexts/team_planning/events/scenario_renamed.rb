# frozen_string_literal: true

# A scenario took a new name. The baseline has no name of its own to change.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :name the new name
#   @option data [String] :previous_name
#   @option data [String] :renamed_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioRenamed < RubyEventStore::Event
end
