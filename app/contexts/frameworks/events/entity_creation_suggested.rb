# frozen_string_literal: true

# Event emitted when a user suggests creating a new framework entity.
#
# Unlike EditSuggested, the target entity does not yet exist — the
# proposed_attributes hash carries the data needed to construct it on
# approval. parent_id identifies the entity the new one would nest under
# (e.g. expectation_id for a role_illustration, category_id for a capability,
# role_id for a level, role_family_id for a role).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :target_entity_type type of entity to create (e.g. "role_illustration")
#   @option data [Hash] :proposed_attributes attributes for the new entity
#   @option data [String, nil] :parent_id UUID of the parent entity, nil for framework-level entities
#   @option data [String] :author_id UUID of the user who created the suggestion
#   @option data [String, nil] :rationale optional explanation
#
class Frameworks::Events::EntityCreationSuggested < RubyEventStore::Event
end
