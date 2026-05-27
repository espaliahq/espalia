# frozen_string_literal: true

# Event emitted on the AssessmentCycle stream when an open cycle is
# rolled forward to a newly-published framework version.
#
# Written by the cross-stream sync handler
# ({AssessmentCycles::SyncHandlers::FrameworkVersionRollSync}) in
# response to {Frameworks::Events::FrameworkVersionPublished}. Lets a
# cycle express the FULL RANGE of framework versions it was open
# against — the original `CycleDefined.framework_version` is the lower
# bound, the latest `FrameworkVersionRolled.new_version` is the upper.
#
# Pairs naturally with the per-person {PersonDevelopment::Events::
# FrameworkVersionMigrated}: the person's ratings/evidence/comments
# follow the migration mappings to the survivor capabilities, and the
# cycle's reading-only `latest_framework_version` advances to match.
#
# Closed cycles are never rolled — the range freezes at close time so
# historical reports show what the cycle actually assessed against.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String]  :cycle_id UUID of the cycle being rolled
#   @option data [String]  :framework_id UUID of the framework
#   @option data [Integer] :new_version newly published framework version
#
class AssessmentCycles::Events::FrameworkVersionRolled < RubyEventStore::Event
end
