# frozen_string_literal: true

# Event emitted when a new assessment cycle is defined.
#
# The first event in the AssessmentCycle stream. Sets the framework_id
# (immutable for the cycle's life) and the framework_version at
# define-time. The version is the lower bound of the range this cycle
# may be open across — when the framework republishes while the cycle
# is still open, {AssessmentCycles::Events::FrameworkVersionRolled}
# advances the upper bound on the read model. See PR #119 for the
# accompanying cross-stream rating/evidence/comment migration that
# carries the data across versions.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :framework_id UUID of the framework being assessed
#   @option data [Integer] :framework_version version frozen at define time
#   @option data [String] :name display name (e.g. "Q1 2026 Review")
#   @option data [String] :cycle_type one of: regular, performance_review, promotion_review
#   @option data [String, nil] :defined_by person_id / tenant_user_id of the creator
#   @option data [String, nil] :planned_end_at ISO 8601 date (YYYY-MM-DD) — soft target
#     completion date. Optional; events emitted before this field was added have it
#     absent (the projection treats absence and nil identically).
#
class AssessmentCycles::Events::CycleDefined < RubyEventStore::Event
end
