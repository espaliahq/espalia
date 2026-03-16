# frozen_string_literal: true

# Event emitted when a reviewer rejects a suggestion, or when a suggestion
# is automatically rejected because a competing suggestion was approved.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :reviewer_id UUID of the reviewer
#   @option data [String, nil] :comment rejection reason
#
class Frameworks::Events::SuggestionRejected < RubyEventStore::Event
end
