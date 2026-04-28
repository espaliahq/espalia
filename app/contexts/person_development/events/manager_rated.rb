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
#   @option data [String] :source "human" (default) when entered by the manager, or
#     "seeded" when carried over from a prior cycle's aligned value at cycle join
#   @option data [String, nil] :seeded_from_cycle_id UUID of the originating cycle
#     when source == "seeded"
#
class PersonDevelopment::Events::ManagerRated < RubyEventStore::Event
end
