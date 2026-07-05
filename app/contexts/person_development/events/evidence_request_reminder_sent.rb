# frozen_string_literal: true

# Emitted when the system nudges the requestee about a still-pending evidence
# request — either because it has gone unanswered for a while (`no_response`)
# or because its optional due date is approaching (`due_soon`).
#
# System-initiated: dispatched by the reminder sweep job, so there is no actor
# in the payload; provenance rides on metadata (`acting_via: "system"`). Each
# kind is sent at most once per request (aggregate-guarded), which is what
# makes the sweep idempotent and replay-safe — the projection stamps the
# per-kind reminded-at columns the sweep's eligibility query reads.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :request_id UUID of the pending request being nudged
#   @option data [String] :kind "no_response" | "due_soon"
#
class PersonDevelopment::Events::EvidenceRequestReminderSent < RubyEventStore::Event
end
