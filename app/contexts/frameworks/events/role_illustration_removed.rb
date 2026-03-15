# frozen_string_literal: true

# Event emitted when a role illustration is removed.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :illustration_id UUID of the illustration
#   @option data [String] :reason reason for removal
#
class Frameworks::Events::RoleIllustrationRemoved < RubyEventStore::Event
end
