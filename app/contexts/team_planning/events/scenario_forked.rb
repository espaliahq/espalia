# frozen_string_literal: true

# A scenario forked from another in the plan. `then` is the step after its
# parent, starting the day after the parent ends, or on the plan's base date
# under the root. `instead` is an alternative over exactly its parent's
# period. Either way the scenario inherits everything its parent resolves to.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id UUID minted by the caller
#   @option data [String] :parent_id a scenario in the plan; the plan_id names the root
#   @option data [String] :relation "then" or "instead"
#   @option data [String] :name
#   @option data [String] :starts_on YYYY-MM-DD, as the tree implied at the fork
#   @option data [String] :ends_on YYYY-MM-DD
#   @option data [String] :forked_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioForked < RubyEventStore::Event
end
