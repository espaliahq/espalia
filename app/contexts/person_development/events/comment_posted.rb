# frozen_string_literal: true

# Event emitted when a comment is posted on a person's development stream.
#
# Comments are the informal-conversation counterpart to evidence —
# they are NOT recorded as official evidence and do NOT feed scoring,
# but they participate in the activity feed timeline so a reader can
# see the context surrounding any rating, evidence, or alignment event.
#
# A comment is individually addressable by `comment_id`. Future
# evidence events may reference a comment to elevate it as evidence
# of a behaviour.
#
# Commentable types: `"assessment_cell"` (discussion about the behaviour
# at a cell) and `"evidence_link"` (discussion about one evidence item's
# bearing on a cell — additionally anchored by `evidence_id`; the anchor
# is the linkage's natural key, so the thread survives link removal and
# re-add). Both use the `(capability_stable_id, level_ordinal)` coordinate
# system shared with ratings and evidence. Future commentable types
# (e.g. growth_plan, focus_area) will set their own identifier shape.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :comment_id UUID v7 of the comment
#   @option data [String, nil] :parent_id UUID of parent comment, nil for top-level
#   @option data [String] :commentable_type "assessment_cell" | "evidence_link"
#   @option data [String, nil] :capability_stable_id stable UUID of the capability
#     (required for both current commentable types)
#   @option data [Integer, nil] :level_ordinal the level coordinate
#     (required for both current commentable types)
#   @option data [String, nil] :evidence_id UUID of the {EvidenceItem}
#     (required when commentable_type == "evidence_link"; absent on
#     events published before the type existed)
#   @option data [String] :body comment body (required, non-blank)
#   @option data [String] :author_id UUID of the Person posting the comment
#
class PersonDevelopment::Events::CommentPosted < RubyEventStore::Event
end
