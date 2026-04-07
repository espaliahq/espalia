# frozen_string_literal: true

# Event emitted when a person's level changes within the same role (promotion).
#
# Used when role_id is unchanged — only the level_id moves to a different
# ordinal within the same role. For cross-role transfers, see
# {PersonDevelopment::Events::PersonRoleChanged}.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :previous_level_id UUID of the previous level
#   @option data [String] :new_level_id UUID of the new level
#   @option data [String] :reason why the change occurred (e.g. "hris_sync")
#
class PersonDevelopment::Events::PersonLevelChanged < RubyEventStore::Event
end
