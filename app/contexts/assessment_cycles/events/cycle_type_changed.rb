# frozen_string_literal: true

# Event emitted when a cycle's type (regular | performance_review |
# promotion_review) is changed by an admin.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :new_cycle_type one of {AssessmentCycles::Aggregate::CYCLE_TYPES}
#   @option data [String, nil] :updated_by person_id / tenant_user_id of the editor
#
class AssessmentCycles::Events::CycleTypeChanged < RubyEventStore::Event
end
