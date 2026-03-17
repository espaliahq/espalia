# frozen_string_literal: true

# Event emitted when the author withdraws their own pending suggestion.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the suggestion
#
class Frameworks::Events::SuggestionWithdrawn < RubyEventStore::Event
end
