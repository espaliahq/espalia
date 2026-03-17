# frozen_string_literal: true

# Event emitted when a reviewer approves a suggestion.
#
# Followed immediately by the actual content change event
# (e.g. RoleIllustrationUpdated) applied by the aggregate.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :reviewer_id UUID of the reviewer
#   @option data [String, nil] :comment optional reviewer comment
#
class Frameworks::Events::SuggestionApproved < RubyEventStore::Event
end
