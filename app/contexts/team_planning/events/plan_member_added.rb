# frozen_string_literal: true

# Someone is now a member of a plan, as an editor or a viewer. Naming a member
# again with another role changes their role.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :person_id the member
#   @option data [String] :role "editor" or "viewer"
#   @option data [String] :added_by_id person_id of the actor
#
class TeamPlanning::Events::PlanMemberAdded < RubyEventStore::Event
end
