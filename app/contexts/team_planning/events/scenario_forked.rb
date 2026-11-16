# frozen_string_literal: true

# A scenario forked from another in the plan. `then` is the step after its
# parent, starting the day after the parent ends, or under the root on its
# `starts_on`, on or after the plan's base date. The days between the base date
# and that start belong to no step. `instead` is an alternative over exactly its parent's
# period. Either way the scenario inherits everything its parent resolves to.
# The last step on a line may have no end date. A `then` after such a step
# starts on its own `starts_on`, and the same event closes that step the day
# before.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id UUID minted by the caller
#   @option data [String] :parent_id a scenario in the plan; the plan_id names the root
#   @option data [String] :relation "then" or "instead"
#   @option data [Shreddable::Value] :name under the plan's key
#   @option data [String] :starts_on YYYY-MM-DD; a first step's own start, else as the tree implied at the fork
#   @option data [String, nil] :ends_on YYYY-MM-DD; nil for a step with no end date
#   @option data [String] :closes_scenario_id the open step this fork closes; absent unless it closes one
#   @option data [String] :closes_on YYYY-MM-DD, that step's new end
#   @option data [String] :forked_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioForked < RubyEventStore::Event
  extend Shreddable
  shreddable :name, by: :plan
end
