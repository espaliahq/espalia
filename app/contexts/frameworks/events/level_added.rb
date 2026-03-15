# frozen_string_literal: true

# Event emitted when a level is added to a role.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :level_id UUID of the new level
#   @option data [String] :role_id UUID of the parent role
#   @option data [Integer] :ordinal seniority ordinal
#   @option data [String] :title display title (e.g. "Senior Engineer")
#   @option data [String] :code short code (e.g. "E3")
#   @option data [Boolean] :is_entry whether this is an entry-level position
#
class Frameworks::Events::LevelAdded < RubyEventStore::Event
end
