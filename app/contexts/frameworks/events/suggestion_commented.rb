# frozen_string_literal: true

# Event emitted when a user comments on a suggestion — a top-level entry in
# the suggestion's discussion thread, or a reply to an existing comment.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :suggestion_id UUID of the suggestion under discussion
#   @option data [String] :comment_id UUID of the new comment (caller-supplied —
#     read-model PK, and the id later edit/delete events target)
#   @option data [String, nil] :parent_id UUID of the comment being replied to;
#     nil for a top-level comment
#   @option data [String] :body the comment text
#   @option data [String] :author_id UUID of the commenter
#
class Frameworks::Events::SuggestionCommented < RubyEventStore::Event
end
