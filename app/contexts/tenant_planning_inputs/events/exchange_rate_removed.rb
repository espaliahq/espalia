# frozen_string_literal: true

# An exchange rate was removed.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :id the rate
#   @option data [String] :at ISO 8601 time of the change, to the microsecond
#   @option data [String, nil] :changed_by_id person_id of the actor, nil when none
#
class TenantPlanningInputs::Events::ExchangeRateRemoved < RubyEventStore::Event
end
