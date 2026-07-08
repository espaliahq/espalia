# frozen_string_literal: true

# Event emitted when a suggestion-thread comment is soft-deleted. The
# comment row survives with status "deleted" so reply chains stay coherent.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :comment_id UUID of the comment being deleted
#   @option data [String] :deleted_by_id UUID of the deleter (author or tenant
#     admin — the author gate lives in the policy layer, not the aggregate)
#   @option data [String, nil] :reason optional explanation
#
class Frameworks::Events::SuggestionCommentDeleted < RubyEventStore::Event
end
