# frozen_string_literal: true

# The plan now covers these units and everything under them, or the whole
# organisation when the list is empty. A plan with no scope event covers the
# whole organisation, as every plan did before
# [#338](https://github.com/espaliahq/espalia/issues/338).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [Array<String>] :unit_ids the covered units, sorted; empty for the whole organisation
#   @option data [String] :set_by_id person_id of the actor
#
class TeamPlanning::Events::PlanScopeSet < RubyEventStore::Event
end
