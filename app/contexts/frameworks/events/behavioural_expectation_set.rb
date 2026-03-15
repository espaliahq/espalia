# frozen_string_literal: true

# Event emitted when a behavioural expectation is set for a capability at a level.
#
# One expectation per Capability × Level ordinal. This is the canonical
# definition people are rated against.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :expectation_id UUID of the expectation
#   @option data [String] :stable_id UUID linking this concept across versions
#   @option data [String] :capability_id UUID of the parent capability
#   @option data [Integer] :level_ordinal seniority level ordinal
#   @option data [String] :description the expectation description
#
class Frameworks::Events::BehaviouralExpectationSet < RubyEventStore::Event
end
