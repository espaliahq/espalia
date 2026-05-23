# frozen_string_literal: true

# Event emitted when a comment is soft-deleted.
#
# The {PersonDevelopmentComment} row stays in the table with
# `status: "deleted"` so reply chains remain coherent and any
# evidence referencing the comment can still resolve it. The
# activity feed renders deleted comments in a tombstone style.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :comment_id UUID of the comment
#   @option data [String] :deleted_by_id UUID of the Person deleting
#   @option data [String, nil] :reason optional explanation
#
class PersonDevelopment::Events::CommentDeleted < RubyEventStore::Event
end
