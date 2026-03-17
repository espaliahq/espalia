# frozen_string_literal: true

# Event emitted when an assessment cycle is opened for a person.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the new cycle
#   @option data [String] :cycle_name display name (e.g. "Q1 2026")
#   @option data [String] :cycle_type one of: regular, performance_review, promotion_review
#   @option data [Integer] :framework_version the framework version this cycle assesses against
#
class PersonDevelopment::Events::AssessmentCycleOpened < RubyEventStore::Event
end
