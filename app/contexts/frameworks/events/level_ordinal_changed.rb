# frozen_string_literal: true

# Event emitted when a level's ordinal is changed.
#
# This is a **shape-changing** event: it renumbers rating rows for any
# in-flight assessment cycle and must only be emitted inside a draft phase.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :level_id UUID of the level
#   @option data [Integer] :new_ordinal the new ordinal position
#   @option data [Integer] :previous_ordinal the ordinal before the change
#   @option data [String] :reason explanation for the change
#
class Frameworks::Events::LevelOrdinalChanged < RubyEventStore::Event
end
