# frozen_string_literal: true

# Event emitted when a role is added to a role family.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :role_id UUID of the new role
#   @option data [String] :role_family_id UUID of the parent role family
#   @option data [String] :name name of the role
#   @option data [String] :code short code (e.g. "E", "EM")
#   @option data [String] :track "ic" or "management"
#
class Frameworks::Events::RoleAdded < RubyEventStore::Event
end
