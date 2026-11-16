# frozen_string_literal: true

# The last step closed was opened again, so the plan stands as it did before
# the close.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :reopened_by_id person_id of the actor
#
class TeamPlanning::Events::StepReopened < RubyEventStore::Event
end
