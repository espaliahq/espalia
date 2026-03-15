# frozen_string_literal: true

# Event emitted when a behavioural expectation description is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :expectation_id UUID of the expectation
#   @option data [String] :new_description the updated description
#   @option data [String] :rationale reason for the change
#
class Frameworks::Events::BehaviouralExpectationUpdated < RubyEventStore::Event
end
