# frozen_string_literal: true

# Event emitted when a manager clears (removes) their rating
# for a capability at a specific level.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being cleared
#
class PersonDevelopment::Events::ManagerRatingCleared < RubyEventStore::Event
end
