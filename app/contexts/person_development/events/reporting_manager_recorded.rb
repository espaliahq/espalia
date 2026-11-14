# frozen_string_literal: true

# Event emitted when a person's reporting manager is recorded on their
# PersonDevelopment stream, as a first-class, immutable domain fact.
#
# Emitted only when the manager actually changes (the aggregate no-ops when the
# recorded manager already matches), so the stream carries the reporting-line
# history rather than a row per sync. Populated from HRIS sync and a one-off
# backfill from the live `Person.manager_id`.
#
# This is the authoritative input for the aggregate's manager-rating invariant
# and for {AssessmentPolicy}'s `manages_assessee?` — both read the projected
# value and fall back to live `Person.manager_id` only when nothing is recorded.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String, nil] :manager_id UUID of the Person who is now the
#     reporting manager, or nil when the HRIS says the person has none
#   @option data [String, nil] :previous_manager_id UUID of the prior recorded
#     manager, or nil when this is the first recording
#   @option data [String] :source "hris" (routine sync) or "backfill" (one-off)
#
class PersonDevelopment::Events::ReportingManagerRecorded < RubyEventStore::Event
end
