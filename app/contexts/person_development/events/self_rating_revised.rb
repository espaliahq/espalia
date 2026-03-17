# frozen_string_literal: true

# Event emitted when a person revises a previous self-rating.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [String] :new_level_id UUID of the revised level
#   @option data [String] :comment optional comment on the revision
#   @option data [String] :rationale reason for the change
#
class PersonDevelopment::Events::SelfRatingRevised < RubyEventStore::Event
end
