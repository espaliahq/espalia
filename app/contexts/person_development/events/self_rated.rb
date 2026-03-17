# frozen_string_literal: true

# Event emitted when a person self-rates a capability at a specific level.
#
# Uses capability stable_id (not capability_id) to enable trend analysis
# across framework versions. Each event captures one (capability, level_ordinal)
# pair — multiple events may exist for the same capability at different levels.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being assessed
#   @option data [String] :frequency "some", "occasional", or "consistent"
#   @option data [String] :comment optional rationale or comment
#
class PersonDevelopment::Events::SelfRated < RubyEventStore::Event
end
