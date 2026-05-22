# frozen_string_literal: true

# Event emitted when a cycle's display name is changed by an admin.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :new_name updated display name
#   @option data [String, nil] :updated_by person_id / tenant_user_id of the editor
#
class AssessmentCycles::Events::CycleRenamed < RubyEventStore::Event
end
