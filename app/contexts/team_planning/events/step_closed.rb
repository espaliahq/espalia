# frozen_string_literal: true

# A step whose period has ended was closed. The next step stands on the Org
# Graph as of the day after `ends_on`, and the closed step, with every step
# before it and every alternative not taken, takes no more changes.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id the step closed, as the timeline lays it out
#   @option data [String] :ends_on YYYY-MM-DD, the last day of its period
#   @option data [String] :base_on YYYY-MM-DD, the plan's base when it closed
#   @option data [String] :closed_by_id person_id of the actor
#
class TeamPlanning::Events::StepClosed < RubyEventStore::Event
end
