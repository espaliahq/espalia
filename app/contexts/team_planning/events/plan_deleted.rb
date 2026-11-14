# frozen_string_literal: true

# A plan was deleted. Nothing more can be written to it. An editor deletes a
# plan; a tenant admin may delete a frozen one, which no editor can reach,
# without opening it, and says why.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :deleted_by_id person_id of the actor
#   @option data [String, nil] :reason why a tenant admin deleted a frozen plan
#
class TeamPlanning::Events::PlanDeleted < RubyEventStore::Event
end
