# frozen_string_literal: true

# Event emitted when a person transfers to a different role within the same framework.
#
# Because level_ids are scoped to roles, switching roles always requires
# selecting a new level — so both `previous_level_id` and `new_level_id`
# are carried on the event.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :previous_role_id UUID of the previous role
#   @option data [String] :new_role_id UUID of the new role
#   @option data [String] :previous_level_id UUID of the previous level
#   @option data [String] :new_level_id UUID of the new level
#   @option data [String] :reason why the change occurred (e.g. "hris_sync")
#   @option data [String, nil] :changed_by UUID of the Person who triggered the
#     change. nil for system-driven HRIS syncs (the actor there is the sync run,
#     carried in event metadata as `acting_via: :hris` + `correlation_id`) and on
#     historical events emitted before attribution was added.
#
class PersonDevelopment::Events::PersonRoleChanged < RubyEventStore::Event
end
