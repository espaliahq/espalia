# frozen_string_literal: true

# Event emitted when an author updates their own pending suggestion.
#
# Updates the suggested_value in place on the existing suggestion,
# preserving the original suggestion_id and any comment thread.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the suggestion being amended
#   @option data [String] :new_suggested_value the revised proposed value
#   @option data [String] :author_id UUID of the author (must match original)
#   @option data [String, nil] :rationale updated explanation
#
class Frameworks::Events::SuggestionAmended < RubyEventStore::Event
end
