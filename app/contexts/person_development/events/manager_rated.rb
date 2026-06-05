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
#   @option data [String, nil] :rated_by_id UUID of the Person (manager) who
#     recorded this rating. The assessee's manager can change over time, so the
#     rater is captured here as a domain fact rather than inferred from the
#     person's *current* manager at read time. nil on historical events emitted
#     before attribution was added, and on "seeded" system carry-forwards.
#   @option data [Boolean, nil] :via_delegation true when recorded by an active
#     delegate rather than the reporting manager (stamped at event time for
#     accurate activity-feed attribution). Absent on historical events.
#
class PersonDevelopment::Events::ManagerRated < RubyEventStore::Event
end
