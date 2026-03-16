# frozen_string_literal: true

# Event emitted when a person is assigned to a framework with a specific role and level.
#
# This is the first event in a person development stream and establishes
# the person's initial role and level context.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :role_id UUID of the assigned role
#   @option data [String] :level_id UUID of the assigned level
#
class PersonDevelopment::Events::PersonAssignedToFramework < RubyEventStore::Event
end
