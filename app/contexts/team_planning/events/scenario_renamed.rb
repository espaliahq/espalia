# frozen_string_literal: true

# A scenario took a new name. The baseline has no name of its own to change.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [Shreddable::Value] :name the new name, under the plan's key
#   @option data [Shreddable::Value, nil] :previous_name under the plan's key, or nil when it couldn't be read
#   @option data [String] :renamed_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioRenamed < RubyEventStore::Event
  extend Shreddable
  shreddable :name, :previous_name, by: :plan
end
