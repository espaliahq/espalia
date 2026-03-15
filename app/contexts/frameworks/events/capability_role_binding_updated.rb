# frozen_string_literal: true

# Event emitted when a capability-role binding is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :binding_id UUID of the binding
#   @option data [BigDecimal] :weight updated weight (optional)
#   @option data [String] :requirement_type updated requirement type (optional)
#
class Frameworks::Events::CapabilityRoleBindingUpdated < RubyEventStore::Event
end
