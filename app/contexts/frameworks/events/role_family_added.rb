# frozen_string_literal: true

# Event emitted when a role family is added to a framework.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :role_family_id UUID of the new role family
#   @option data [String] :name name of the role family
#   @option data [String] :description optional description
#   @option data [String] :department optional department grouping label
#
class Frameworks::Events::RoleFamilyAdded < RubyEventStore::Event
end
