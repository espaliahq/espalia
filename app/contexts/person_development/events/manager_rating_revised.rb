# frozen_string_literal: true

# Event emitted when a manager revises a previous rating at a specific level.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being revised
#   @option data [String] :frequency revised frequency: "some", "occasional", or "consistent"
#   @option data [String] :comment optional comment on the revision
#   @option data [String] :rationale reason for the change
#
class PersonDevelopment::Events::ManagerRatingRevised < RubyEventStore::Event
end
