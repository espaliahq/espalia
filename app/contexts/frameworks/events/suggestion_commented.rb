# frozen_string_literal: true

# Event emitted when a user comments on a suggestion.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :author_id UUID of the commenter
#   @option data [String] :content the comment text
#
class Frameworks::Events::SuggestionCommented < RubyEventStore::Event
end
