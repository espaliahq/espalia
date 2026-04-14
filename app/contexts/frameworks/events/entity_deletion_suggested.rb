# frozen_string_literal: true

# Event emitted when a user suggests deleting (or archiving) a framework entity.
#
# On approval, the aggregate dispatches the matching destructive command for
# the entity type — e.g. archive_capability for a capability, remove_role_illustration
# for an illustration. For shape-changing deletions (capability, level), the
# dispatched command's draft guard will fire if no draft is in progress.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :target_entity_type type of entity (e.g. "capability")
#   @option data [String] :target_entity_id UUID of the entity to delete
#   @option data [String] :author_id UUID of the user who created the suggestion
#   @option data [String, nil] :rationale optional explanation
#
class Frameworks::Events::EntityDeletionSuggested < RubyEventStore::Event
end
