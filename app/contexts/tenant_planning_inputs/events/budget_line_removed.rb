# frozen_string_literal: true

# A line was removed from the tenant's approved budget.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :id the line
#   @option data [String] :at ISO 8601 time of the change, to the microsecond
#   @option data [String, nil] :changed_by_id person_id of the actor, nil when none
#
class TenantPlanningInputs::Events::BudgetLineRemoved < RubyEventStore::Event
end
