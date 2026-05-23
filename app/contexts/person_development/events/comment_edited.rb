# frozen_string_literal: true

# Event emitted when the author edits an existing comment's body.
#
# Carries the full post-edit body (snapshot, not delta) so the
# projection can apply it without ambiguity.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :comment_id UUID of the comment being edited
#   @option data [String] :body post-edit body (required, non-blank)
#   @option data [String] :edited_by_id UUID of the Person performing the edit
#     (always the original author — enforced by {CommentPolicy#update?})
#
class PersonDevelopment::Events::CommentEdited < RubyEventStore::Event
end
