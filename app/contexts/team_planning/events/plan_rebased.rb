# frozen_string_literal: true

# The plan now stands on a later day. Nothing else is rewritten: every
# scenario resolves its changes over the Org Graph as of the new base.
#
# Today reads the new base, so a change that disagreed with reality would read
# pending from here on. `conflicts` keeps each one in view: the key of every
# change that read conflicting at the moment of the move, never its value,
# with the scenario it read conflicting in and the change that scenario
# resolved to.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :base_on YYYY-MM-DD, the new base
#   @option data [String] :previous_base_on YYYY-MM-DD
#   @option data [Array<Hash>] :conflicts `{ scenario_id, subject_id, facet, change_id }`
#   @option data [String] :rebased_by_id person_id of the actor
#   @option data [String] :time_zone the tenant's zone, as on {TeamPlanning::Events::PlanCreated}
#
class TeamPlanning::Events::PlanRebased < RubyEventStore::Event
end
