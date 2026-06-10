# frozen_string_literal: true

# Event emitted when a person's framework assignment is removed entirely —
# the exit from the assign → change_role → change_level lifecycle.
#
# Used when the person's real role no longer maps to any framework role (a
# transfer out of the framework's scope) or to correct an erroneous
# assignment. The full assignment history stays on the stream; only the
# read-model row is removed. After unassignment the person may be assigned
# again (the assignment guard keys off the in-memory `@assigned` flag).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String, nil] :previous_role_id UUID of the role held at unassignment
#   @option data [String, nil] :previous_level_id UUID of the level held at unassignment
#   @option data [String] :reason why the assignment was removed (e.g. "manual",
#     "role_unmapped", "data_correction")
#   @option data [String, nil] :unassigned_by UUID of the Person who triggered the
#     removal. nil for system-driven actions and on historical events emitted
#     before attribution was added.
#
class PersonDevelopment::Events::PersonUnassignedFromFramework < RubyEventStore::Event
end
