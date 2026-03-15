# frozen_string_literal: true

# Event emitted when a level is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :level_id UUID of the level
#   @option data [Integer] :ordinal updated ordinal (optional)
#   @option data [String] :title updated title (optional)
#   @option data [String] :code updated code (optional)
#
class Frameworks::Events::LevelUpdated < RubyEventStore::Event
end
