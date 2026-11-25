# frozen_string_literal: true

# The model proposed a cell and valence for a piece of evidence, for a person
# to accept or dismiss. The suggestion id stays fixed per evidence item and
# cell: a later run that proposes the same cell again reuses it.
#
# Accepting writes no event of its own. The EvidenceLinkAdded or
# EvidenceLinkRevalenced it writes carries `via_suggestion_id`, and that is the
# outcome.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id
#   @option data [String] :evidence_id
#   @option data [String] :capability_stable_id the proposed cell's capability
#   @option data [Integer] :level_ordinal the proposed cell's level
#   @option data [String] :valence one of EvidenceLink::VALENCES
#   @option data [String] :confidence a decimal string from "0" to "1"
#   @option data [String, nil] :rationale the model's sentence about the evidence
#   @option data [String] :provider one of AiModelConfig::PROVIDERS
#   @option data [String] :model
#   @option data [String] :prompt_version
#   @option data [String] :generated_at ISO 8601 time the model answered
#   @option data [Boolean] :already_held true when recorded from a suggestion made before suggestions were events
#   @option data [String, nil] :status only with already_held: the row's status when recorded,
#     one of EvidencePlacementSuggestion::STATUSES other than "dismissed"
#   @option data [String, nil] :decided_by_id only with already_held: the person_id of who accepted it, when no
#     link names it
#   @option data [String, nil] :decided_at only with already_held: ISO 8601 time it was accepted
#
class PersonDevelopment::Events::EvidencePlacementSuggested < RubyEventStore::Event
end
