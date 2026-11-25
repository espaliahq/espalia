# frozen_string_literal: true

# A line was added to the tenant's approved budget.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :id the row id, minted when the command ran
#   @option data [Hash] :row every column of the row but its id, tenant and bookkeeping
#   @option data [Boolean] :already_held true when recorded from a row held before it was an event
#   @option data [String, nil] :last_changed_by_id with already_held, person_id of whoever last changed the row
#   @option data [String, nil] :created_at with already_held, when the row was created
#   @option data [String] :at ISO 8601 time of the change, to the microsecond
#   @option data [String, nil] :changed_by_id person_id of the actor, nil when none
#
class TenantPlanningInputs::Events::BudgetLineAdded < RubyEventStore::Event
end
