# frozen_string_literal: true

# Event emitted when a capability category is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :category_id UUID of the category
#   @option data [String] :name updated name (optional)
#   @option data [String] :description updated description (optional)
#   @option data [Integer] :ordinal updated ordinal (optional)
#
class Frameworks::Events::CapabilityCategoryUpdated < RubyEventStore::Event
end
