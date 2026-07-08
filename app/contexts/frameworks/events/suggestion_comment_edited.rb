# frozen_string_literal: true

# Event emitted when a suggestion-thread comment's body is revised by its
# author.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :comment_id UUID of the comment being edited
#   @option data [String] :body the revised comment text
#   @option data [String] :edited_by_id UUID of the editor (always the author —
#     enforced by the aggregate)
#
class Frameworks::Events::SuggestionCommentEdited < RubyEventStore::Event
end
