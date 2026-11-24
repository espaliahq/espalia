# frozen_string_literal: true

# A tenant turned on the daily job that forgets leavers once their retention
# period ends.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :enabled_at ISO 8601 time it was turned on
#   @option data [String, nil] :enabled_by_id person_id of the actor, nil when none
#   @option data [Integer, nil] :confirmed_count how many were due when the admin confirmed, nil when already held
#   @option data [Boolean] :already_held true when recorded from a setting made before it was an event
#
class TenantSettings::Events::ScheduledForgettingEnabled < RubyEventStore::Event
end
