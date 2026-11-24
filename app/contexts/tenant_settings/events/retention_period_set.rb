# frozen_string_literal: true

# A tenant set how many years after a person leaves the Org Graph forgets them.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [Integer, nil] :retention_years the period now, nil for never
#   @option data [Integer, nil] :previous the period before, nil for never
#   @option data [String, nil] :set_by_id person_id of the actor, nil when none
#   @option data [Boolean] :already_held true when recorded from a setting made before it was an event
#
class TenantSettings::Events::RetentionPeriodSet < RubyEventStore::Event
end
