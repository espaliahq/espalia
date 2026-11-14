# frozen_string_literal: true

# A plan member may no longer see pay in the plan. Taking someone off the plan
# withdraws it without this event, and adding them back does not restore it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :person_id the member
#   @option data [String] :withdrawn_by_id person_id of the actor
#
class TeamPlanning::Events::SeePayWithdrawn < RubyEventStore::Event
end
