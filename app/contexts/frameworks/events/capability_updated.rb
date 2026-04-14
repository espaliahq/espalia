# frozen_string_literal: true

# Event emitted when a capability's name or description is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :capability_id UUID of the capability
#   @option data [String] :name updated name (optional)
#   @option data [String] :description updated description (optional)
#
class Frameworks::Events::CapabilityUpdated < RubyEventStore::Event
end
