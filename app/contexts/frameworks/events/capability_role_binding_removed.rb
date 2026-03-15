# frozen_string_literal: true

# Event emitted when a capability-role binding is removed.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :binding_id UUID of the binding
#
class Frameworks::Events::CapabilityRoleBindingRemoved < RubyEventStore::Event
end
