# frozen_string_literal: true

# Event emitted when a person is removed from an open assessment cycle.
#
# Self-describing: carries framework_id so the cross-stream sync handler
# can dispatch to the PersonDevelopment aggregate.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :person_id UUID of the unenrolled person
#   @option data [String] :framework_id UUID of the framework (from cycle state)
#   @option data [String] :reason why the person was unenrolled
#   @option data [String, nil] :unenrolled_by person_id / tenant_user_id
#
class AssessmentCycles::Events::PersonUnenrolled < RubyEventStore::Event
end
