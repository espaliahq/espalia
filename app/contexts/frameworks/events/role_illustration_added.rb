# frozen_string_literal: true

# Event emitted when a role-specific illustration is added to an expectation.
#
# Illustrations are clarifying examples — NOT separately rated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :illustration_id UUID of the new illustration
#   @option data [String] :stable_id UUID linking this concept across versions
#   @option data [String] :expectation_id UUID of the parent expectation
#   @option data [String] :role_id UUID of the role this illustrates for
#   @option data [Integer] :ordinal display order
#   @option data [String] :description the illustration text
#
class Frameworks::Events::RoleIllustrationAdded < RubyEventStore::Event
end
