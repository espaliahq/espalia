# frozen_string_literal: true

# Event emitted when the framework's capability categories are reordered.
# Carries the complete new display order — one atomic event per reorder, so
# the activity feed shows one entry rather than N ordinal updates.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [Array<String>] :new_ordering ordered list of category_ids
#     (every active category, in display order)
#
class Frameworks::Events::CapabilityCategoryReordered < RubyEventStore::Event
end
