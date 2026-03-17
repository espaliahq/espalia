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
#   @option data [BigDecimal, nil] :individual_tolerance nil = category-governed,
#     0 = mandatory, N = deficit capped at N before entering category pool
#
class Frameworks::Events::CapabilityRoleBindingCreated < RubyEventStore::Event
end
