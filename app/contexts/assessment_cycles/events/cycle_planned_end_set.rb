# frozen_string_literal: true

# Event emitted when an admin sets, changes, or clears a cycle's planned
# end date. The planned end is a soft deadline for participants — it does
# not affect any domain invariant.
#
# A nil `planned_end_at` clears any previously-set value.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String, nil] :planned_end_at ISO 8601 date (YYYY-MM-DD) or nil to clear
#   @option data [String, nil] :updated_by person_id / tenant_user_id of the editor
#
class AssessmentCycles::Events::CyclePlannedEndSet < RubyEventStore::Event
end
