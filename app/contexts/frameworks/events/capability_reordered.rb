# frozen_string_literal: true

# Event emitted when a category's capabilities are reordered. Carries the
# complete new display order for that category — one atomic event per
# reorder, so the activity feed shows one entry rather than N ordinal updates.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :category_id UUID of the category being reordered
#   @option data [Array<String>] :new_ordering ordered list of capability_ids
#     (every active capability in the category, in display order)
#
class Frameworks::Events::CapabilityReordered < RubyEventStore::Event
end
