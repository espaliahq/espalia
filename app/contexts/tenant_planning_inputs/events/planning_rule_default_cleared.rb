# frozen_string_literal: true

# A rule default the stream held is no longer in the table. Only reconcile records it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :id the row
#   @option data [String] :rule the rule it set
#   @option data [String] :at ISO 8601 time of the change, to the microsecond
#   @option data [String, nil] :changed_by_id person_id of the actor, nil when none
#
class TenantPlanningInputs::Events::PlanningRuleDefaultCleared < RubyEventStore::Event
end
