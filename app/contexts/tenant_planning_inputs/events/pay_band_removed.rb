# frozen_string_literal: true

# A pay band was removed from the tenant's list.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :id the band
#   @option data [Array<String>, nil] :order every band id in order afterwards; nil leaves the other bands where they are
#   @option data [String] :bands_changed_at when the bands last changed, for every plan's "as of"
#   @option data [String] :at ISO 8601 time of the change, to the microsecond
#   @option data [String, nil] :changed_by_id person_id of the actor, nil when none
#
class TenantPlanningInputs::Events::PayBandRemoved < RubyEventStore::Event
end
