# frozen_string_literal: true

# Event emitted when an evidence item is withdrawn (soft-deleted).
#
# Withdrawn evidence is retained in the read model with `link_status:
# "withdrawn"` so the activity feed can render it (struck-through) and
# audit history is preserved. It no longer counts toward the in-cell
# evidence badge or the evidence-density reporting metric.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID of the evidence item
#   @option data [String] :withdrawn_by_id UUID of the Person withdrawing
#   @option data [String, nil] :reason optional explanation
#
class PersonDevelopment::Events::EvidenceWithdrawn < RubyEventStore::Event
end
