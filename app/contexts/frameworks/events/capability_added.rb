# frozen_string_literal: true

# Event emitted when a capability is added to a category.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :capability_id UUID of the new capability
#   @option data [String] :stable_id UUID linking this concept across versions
#   @option data [String] :category_id UUID of the parent category
#   @option data [String] :name name of the capability
#   @option data [String] :description optional description
#
class Frameworks::Events::CapabilityAdded < RubyEventStore::Event
end
