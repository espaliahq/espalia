# frozen_string_literal: true

# Event emitted when a capability is bound to a role.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :binding_id UUID of the new binding
#   @option data [String] :capability_id UUID of the capability
#   @option data [String] :role_id UUID of the role
#   @option data [BigDecimal] :weight relative weight (default 1.0)
#   @option data [String] :requirement_type "must_have" or "flexible"
#
class Frameworks::Events::CapabilityRoleBindingCreated < RubyEventStore::Event
end
