# frozen_string_literal: true

# Event emitted when a capability is archived.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :capability_id UUID of the capability
#   @option data [String] :reason reason for archiving
#
class Frameworks::Events::CapabilityArchived < RubyEventStore::Event
end
