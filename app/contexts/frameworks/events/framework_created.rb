# frozen_string_literal: true

# Event emitted when a new framework is created.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the created framework
#   @option data [String] :name name of the framework
#
class Frameworks::Events::FrameworkCreated < RubyEventStore::Event
end
