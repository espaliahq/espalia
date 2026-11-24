# frozen_string_literal: true

# A tenant's scheduled forgetting was turned off. Nobody forgotten comes back.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String, nil] :disabled_by_id person_id of the actor, nil when none
#   @option data [String, nil] :reason "by_admin", or "period_shortened" when a shorter period turned it off;
#     nil when already held
#   @option data [Boolean] :already_held true when recorded from a setting made before it was an event
#
class TenantSettings::Events::ScheduledForgettingDisabled < RubyEventStore::Event
end
