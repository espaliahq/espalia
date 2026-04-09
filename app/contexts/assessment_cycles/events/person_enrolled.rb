# frozen_string_literal: true

# Event emitted when a person is enrolled in an open assessment cycle.
#
# Self-describing: carries framework_id + framework_version so the
# cross-stream sync handler can dispatch to the PersonDevelopment
# aggregate without reading any read model.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :person_id UUID of the enrolled person
#   @option data [String] :framework_id UUID of the framework (from cycle state)
#   @option data [Integer] :framework_version frozen framework version (from cycle state)
#   @option data [String, nil] :enrolled_by person_id / tenant_user_id of the enroller
#
class AssessmentCycles::Events::PersonEnrolled < RubyEventStore::Event
end
