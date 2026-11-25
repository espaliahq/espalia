# frozen_string_literal: true

# The tenant's pay bands were put in a new order.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [Array<String>, nil] :order every band id, position 1 first
#   @option data [String] :bands_changed_at when the bands last changed, for every plan's "as of"
#   @option data [String] :at ISO 8601 time of the change, to the microsecond
#   @option data [String, nil] :changed_by_id person_id of the actor, nil when none
#
class TenantPlanningInputs::Events::PayBandsReordered < RubyEventStore::Event
end
