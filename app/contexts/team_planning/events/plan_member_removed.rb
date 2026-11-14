# frozen_string_literal: true

# Someone is no longer a member of a plan: an editor took them off, or they
# left it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :person_id the former member
#   @option data [String] :removed_by_id person_id of the actor
#
class TeamPlanning::Events::PlanMemberRemoved < RubyEventStore::Event
end
