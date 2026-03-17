# frozen_string_literal: true

# Event emitted when a person self-rates against a capability.
#
# Uses capability stable_id (not capability_id) to enable trend analysis
# across framework versions.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [String] :level_id UUID of the level the person rates themselves at
#   @option data [String] :comment optional rationale or comment
#
class PersonDevelopment::Events::SelfRated < RubyEventStore::Event
end
