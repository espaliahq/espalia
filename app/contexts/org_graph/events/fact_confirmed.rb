# frozen_string_literal: true

# That a fact Espalia holds about a person is still true, and who said so.
#
# Names the fact, never its value, so a confirmation can't disagree with the
# fact it confirms.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider always "espalia", the only provider whose facts are confirmed
#   @option data [String] :effective_on ISO date of the confirmation
#   @option data [String] :fact a person fact key (`title`, `manager_id`, …) or `membership`
#   @option data [String, nil] :unit_id the unit, for a membership
#   @option data [String] :confirmed_by_id person_id of whoever confirmed it
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::FactConfirmed < RubyEventStore::Event
end
