# frozen_string_literal: true

# Event emitted when a role illustration description is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :illustration_id UUID of the illustration
#   @option data [String] :new_description the updated description
#   @option data [String] :rationale reason for the change
#
class Frameworks::Events::RoleIllustrationUpdated < RubyEventStore::Event
end
