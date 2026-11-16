# frozen_string_literal: true

# A `then` scenario now ends on another day, and a first step may start on
# another. A later step's start is the tree's to say; the steps after it start
# from the new end.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :starts_on YYYY-MM-DD; a first step's own start, a later one's as the tree had it
#   @option data [String] :ends_on YYYY-MM-DD, the new end
#   @option data [String] :previous_starts_on YYYY-MM-DD; absent from events written before a first step could move its start
#   @option data [String] :previous_ends_on YYYY-MM-DD
#   @option data [String] :set_by_id person_id of the actor
#
class TeamPlanning::Events::ScenarioPeriodSet < RubyEventStore::Event
end
