# frozen_string_literal: true

# Event emitted when a person revises a previous self-rating at a specific level.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being revised
#   @option data [String] :frequency revised frequency: "some", "occasional", or "consistent"
#   @option data [String] :cycle_id UUID of the cycle this rating belongs to
#   @option data [String] :comment optional comment on the revision
#   @option data [String] :rationale reason for the change
#   @option data [String, nil] :via_role_id the role whose cells the rater was
#     reading through a lens (ADR-22) — provenance only, never a scoping key;
#     nil or absent for the home role and on every event before the lens
#
class PersonDevelopment::Events::SelfRatingRevised < RubyEventStore::Event
end
