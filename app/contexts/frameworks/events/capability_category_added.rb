# frozen_string_literal: true

# Event emitted when a capability category is added to a framework.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :category_id UUID of the new category
#   @option data [String] :name name of the category
#   @option data [String] :description optional description
#   @option data [Integer] :ordinal display order
#   @option data [BigDecimal, nil] :category_tolerance nil = uncapped,
#     0 = group must balance, N = group absorbs up to N weighted points of deficit
#
class Frameworks::Events::CapabilityCategoryAdded < RubyEventStore::Event
end
