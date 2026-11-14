# frozen_string_literal: true

# A plan took a new name.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :name the new name
#   @option data [String] :previous_name
#   @option data [String] :renamed_by_id person_id of the actor
#
class TeamPlanning::Events::PlanRenamed < RubyEventStore::Event
end
