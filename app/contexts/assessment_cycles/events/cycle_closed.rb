# frozen_string_literal: true

# Event emitted when an assessment cycle is closed.
#
# Carries the full list of enrolled_person_ids so the cross-stream sync
# handler can dispatch leave_cycle to every person's PersonDev stream
# without a read-model lookup.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :framework_id UUID of the framework
#   @option data [Array<String>] :enrolled_person_ids UUIDs of persons still enrolled at close
#   @option data [String, nil] :closed_by person_id / tenant_user_id
#
class AssessmentCycles::Events::CycleClosed < RubyEventStore::Event
end
