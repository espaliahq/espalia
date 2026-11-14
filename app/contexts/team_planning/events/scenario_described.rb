# frozen_string_literal: true

# A scenario was given a description, or had it cleared. The description is
# sealed under the plan's key, so deleting the plan forgets it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [Shreddable::Value, nil] :description what the scenario is
#     for; nil clears it
#   @option data [String] :described_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioDescribed < RubyEventStore::Event
  extend Shreddable
  shreddable :description, by: :plan
end
