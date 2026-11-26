# frozen_string_literal: true

# Event emitted when a capability category's deficit threshold is set.
#
# Scoring reads it as the fallback threshold for the category's capabilities
# and as the category's pool tolerance for net weighted deficit.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :category_id UUID of the category
#   @option data [String, nil] :deficit_threshold the threshold as a decimal
#     string (nil = inherit the framework's; "0.0" = the deficit must balance)
#
class Frameworks::Events::CapabilityCategoryDeficitThresholdSet < RubyEventStore::Event
end
