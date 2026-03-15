# frozen_string_literal: true

# Event emitted when a role is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :role_id UUID of the role
#   @option data [String] :name updated name (optional)
#   @option data [String] :code updated code (optional)
#   @option data [String] :track updated track (optional)
#
class Frameworks::Events::RoleUpdated < RubyEventStore::Event
end
