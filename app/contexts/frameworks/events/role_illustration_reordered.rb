# frozen_string_literal: true

# Event emitted when illustrations for an expectation and role are reordered.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :expectation_id UUID of the expectation
#   @option data [String] :role_id UUID of the role
#   @option data [Array<String>] :new_ordering ordered list of illustration_ids
#
class Frameworks::Events::RoleIllustrationReordered < RubyEventStore::Event
end
