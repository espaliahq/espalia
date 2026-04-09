# frozen_string_literal: true

# Event emitted when a manager rates a person's capability at a specific level.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being assessed
#   @option data [String] :frequency "some", "occasional", or "consistent"
#   @option data [String] :cycle_id UUID of the cycle this rating belongs to
#   @option data [String] :comment optional rationale or comment
#
class PersonDevelopment::Events::ManagerRated < RubyEventStore::Event
end
