# frozen_string_literal: true

# Event emitted when a migration mapping is defined during a draft phase.
#
# Maps a capability (by stable_id) from the current published version to
# the draft version. Used to migrate person development assessments when
# the framework version changes.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :mapping_id UUID of this mapping
#   @option data [String] :from_stable_id stable_id in the current published version
#   @option data [String] :to_stable_id stable_id in the draft version (nil for archived)
#   @option data [String] :mapping_type one of: same, evolved, split, archived, new
#   @option data [Boolean] :requires_reassessment whether existing ratings need review
#   @option data [String] :reason human-readable explanation of the mapping
#
class Frameworks::Events::MigrationMappingDefined < RubyEventStore::Event
end
