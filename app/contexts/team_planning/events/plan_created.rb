# frozen_string_literal: true

# Someone opened a plan. It stands on the Org Graph as of its base date, read
# as known at the end of the day before.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :name
#   @option data [String] :base_on ISO 8601 date the plan stands on
#   @option data [String] :created_by_id person_id of the plan's creator
#
class TeamPlanning::Events::PlanCreated < RubyEventStore::Event
end
