# frozen_string_literal: true

# Event emitted when someone asks for clarification of a behavioural
# expectation (or of a capability × level cell with no expectation yet).
#
# A clarification is a NON-PROPOSAL suggestion kind: it anchors a lifecycled
# discussion on the entity without proposing a concrete value. It is resolved
# with a note (see {Frameworks::Events::ClarificationResolved}) or withdrawn —
# never approved/rejected. See docs/architecture/calibration-sessions.md →
# "The clarification kind".
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :suggestion_id UUID of the suggestion
#   @option data [String] :target_entity_type "behavioural_expectation" or
#     "capability" (the latter when the cell has no expectation to anchor)
#   @option data [String] :target_entity_id UUID of the anchored entity
#   @option data [Integer, nil] :level_ordinal the level the question concerns —
#     carried explicitly for capability anchors (an expectation implies its level)
#   @option data [String] :author_id UUID of the requester
#   @option data [String] :rationale the question itself — what is unclear
#
class Frameworks::Events::ClarificationRequested < RubyEventStore::Event
end
