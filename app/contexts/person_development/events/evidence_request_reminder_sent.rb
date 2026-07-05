# frozen_string_literal: true

# Emitted when the requestee is nudged about a still-pending evidence
# request — automatically because it has gone unanswered for a while
# (`no_response`) or its optional due date is approaching (`due_soon`), or
# manually by the requester (`manual`).
#
# Automatic kinds are dispatched by the reminder sweep job with no actor in
# the payload (provenance rides on metadata, `acting_via: "system"`) and are
# sent at most once per request (aggregate-guarded) — which is what makes the
# sweep idempotent and replay-safe. Manual nudges carry `nudged_by_id` (a
# domain fact the hub's history timeline surfaces) and may repeat, spaced by
# operation-layer timing policy. The projection appends every reminder to the
# read model's history and stamps the columns the sweep + nudge gates read.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :request_id UUID of the pending request being nudged
#   @option data [String] :kind "no_response" | "due_soon" | "manual"
#   @option data [String, nil] :nudged_by_id Person who nudged (manual only;
#     absent on early events)
#
class PersonDevelopment::Events::EvidenceRequestReminderSent < RubyEventStore::Event
end
