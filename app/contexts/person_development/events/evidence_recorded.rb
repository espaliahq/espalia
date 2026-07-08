# frozen_string_literal: true

# Event emitted when evidence is recorded against a (capability, level)
# coordinate on a person's development stream.
#
# Evidence is qualitative context — it does not feed scoring (per ADR-10
# and scoring-model.md). It surfaces in the assessment matrix expanded
# row alongside illustrations, and in the activity feed.
#
# Anchored to (capability_stable_id, level_ordinal) — the same coordinate
# system used by ratings and behavioural expectations — so evidence stays
# associated with the expectation it's evidence for, even across role
# transitions and framework versions.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID v7 of the evidence item
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level being evidenced
#   @option data [String] :source "self" | "manager" | "peer"
#   @option data [String] :evidence_type one of EvidenceItem::EVIDENCE_TYPES
#   @option data [String, nil] :custom_type_label free text label, only
#     populated when evidence_type == "other"
#   @option data [String, nil] :title optional one-line summary
#   @option data [String] :content the body of the evidence (required)
#   @option data [Hash, nil] :external_reference optional pointer to an
#     external system. Shape: { system:, url:, external_id:, metadata: }
#   @option data [String] :author_id UUID of the Person recording the evidence
#   @option data [String] :valence the origin link's valence — one of
#     EvidenceLink::VALENCES. Required on new events; absent on events
#     published before valence existed (consumers must tolerate nil).
#
class PersonDevelopment::Events::EvidenceRecorded < RubyEventStore::Event
end
