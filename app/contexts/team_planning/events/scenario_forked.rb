# frozen_string_literal: true

# A scenario forked from another in the plan. `then` is the step after its
# parent, starting the day after the parent ends, or under the root on its
# `starts_on`, on or after the plan's base date. The days between the base date
# and that start belong to no step. `instead` is an alternative over exactly its parent's
# period. Either way the scenario inherits everything its parent resolves to.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id UUID minted by the caller
#   @option data [String] :parent_id a scenario in the plan; the plan_id names the root
#   @option data [String] :relation "then" or "instead"
#   @option data [Shreddable::Value] :name under the plan's key
#   @option data [String] :starts_on YYYY-MM-DD; a first step's own start, else as the tree implied at the fork
#   @option data [String] :ends_on YYYY-MM-DD
#   @option data [String] :forked_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioForked < RubyEventStore::Event
  extend Shreddable
  shreddable :name, by: :plan
end
