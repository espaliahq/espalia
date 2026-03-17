# frozen_string_literal: true

# Event emitted when the tolerance for a capability category is set or updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :category_id UUID of the category
#   @option data [BigDecimal, nil] :category_tolerance nil = uncapped,
#     0 = group must balance, N = absorbs up to N weighted points of deficit
#
class Frameworks::Events::CategoryToleranceSet < RubyEventStore::Event
end
