# frozen_string_literal: true

# Event emitted when a user suggests an edit to a framework entity.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :target_entity_type type of entity being edited (e.g. "role_illustration")
#   @option data [String] :target_entity_id UUID of the entity being edited
#   @option data [String] :field the field being edited (e.g. "description")
#   @option data [String] :suggested_value the proposed new value
#   @option data [String] :author_id UUID of the user who created the suggestion
#   @option data [String, nil] :rationale optional explanation
#
class Frameworks::Events::EditSuggested < RubyEventStore::Event
end
