# frozen_string_literal: true

# Event emitted on a PersonDev stream when the framework this person is
# assessed against is republished at a new version and the cross-stream
# sync handler ({Frameworks::SyncHandlers::FrameworkVersionMigrationSync})
# fires to carry the person's ratings / evidence / comments onto the new
# capability stable_ids.
#
# Self-describing on purpose: the full mappings payload + per-capability
# counts are embedded so the projections and the activity feed can do
# their work without joining back to the framework stream.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String]  :framework_id UUID of the framework that was republished
#   @option data [Integer] :old_version previous published version
#   @option data [Integer] :new_version newly published version
#   @option data [Array<Hash>] :mappings one entry per archived capability:
#     - :from_stable_id [String]
#     - :to_stable_id   [String, nil] nil when archived/split with no
#       single survivor
#     - :mapping_type   [String] one of: same, evolved, split, archived, new
#     - :requires_reassessment [Boolean]
#     - :from_capability_name [String, nil] human label for activity feed
#     - :to_capability_name   [String, nil] human label for activity feed
#     - :counts [Hash{Symbol=>Integer}] { ratings:, evidence:, comments: }
#       counted on the person's read models before dispatch
#
class PersonDevelopment::Events::FrameworkVersionMigrated < RubyEventStore::Event
end
