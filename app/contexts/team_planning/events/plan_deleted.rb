# frozen_string_literal: true

# A plan was deleted. Nothing more can be written to it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :deleted_by_id person_id of the actor
#
class TeamPlanning::Events::PlanDeleted < RubyEventStore::Event
end
