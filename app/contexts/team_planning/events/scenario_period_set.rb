# frozen_string_literal: true

# A `then` scenario now ends on another day. Its start is the tree's to say,
# so only the end moves; the steps after it start from the new end.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :starts_on YYYY-MM-DD, as the tree had it
#   @option data [String] :ends_on YYYY-MM-DD, the new end
#   @option data [String] :previous_ends_on YYYY-MM-DD
#   @option data [String] :set_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioPeriodSet < RubyEventStore::Event
end
