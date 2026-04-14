# frozen_string_literal: true

# Event emitted when a level's editorial details are updated.
#
# Shape-preserving: this event does not alter rating rows. For ordinal
# changes (which are shape-changing), see LevelOrdinalChanged.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :level_id UUID of the level
#   @option data [String] :title updated title (optional)
#   @option data [String] :code updated code (optional)
#   @option data [Boolean] :is_entry updated entry-level flag (optional)
#
class Frameworks::Events::LevelUpdated < RubyEventStore::Event
end
