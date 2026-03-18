# frozen_string_literal: true

# Event emitted when a person clears (removes) their self-rating
# for a capability at a specific level.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being cleared
#
class PersonDevelopment::Events::SelfRatingCleared < RubyEventStore::Event
end
