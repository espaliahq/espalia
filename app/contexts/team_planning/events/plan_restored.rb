# frozen_string_literal: true

# An archived plan was brought back exactly as it was archived. It takes
# changes again and is checked against the organisation from its base.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :restored_by_id person_id of the editor
#
class TeamPlanning::Events::PlanRestored < RubyEventStore::Event
end
