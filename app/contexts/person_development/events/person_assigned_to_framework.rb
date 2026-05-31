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
#   @option data [String, nil] :assigned_by UUID of the Person who triggered the
#     assignment. nil for system-driven HRIS syncs (the actor there is the sync
#     run, carried in event metadata as `acting_via: :hris` + `correlation_id`)
#     and on historical events emitted before attribution was added.
#
class PersonDevelopment::Events::PersonAssignedToFramework < RubyEventStore::Event
end
