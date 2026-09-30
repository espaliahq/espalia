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
#   @option data [String] :cycle_id UUID of the cycle this rating belongs to
#   @option data [String] :comment optional rationale or comment
#   @option data [String] :source "human" (default) when entered by the person, or
#     "seeded" when carried over from a prior cycle's aligned value at cycle join
#   @option data [String, nil] :seeded_from_cycle_id UUID of the originating cycle
#     when source == "seeded"
#   @option data [String, nil] :via_role_id the role whose cells the rater was
#     reading through a lens (ADR-22) — provenance only, never a scoping key;
#     nil or absent for the home role and on every event before the lens
#
class PersonDevelopment::Events::SelfRated < RubyEventStore::Event
end
