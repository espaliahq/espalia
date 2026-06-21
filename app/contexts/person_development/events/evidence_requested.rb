# frozen_string_literal: true

# Emitted when someone asks a colleague (a peer) to provide evidence for a
# specific (capability, level) cell of a person's assessment.
#
# Requests are cell-scoped: the requestee is asked for evidence about one
# behavioural expectation, so a response lands pre-linked to the right cell.
# The requester is the assessee themselves or someone in their manager chain
# (enforced by policy); the requestee is any other person in the tenant.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :request_id UUID v7 of the request (minted at command
#     time so the read-model PK is replay-stable and deep links survive rebuilds)
#   @option data [String] :requested_by_id Person who made the request
#   @option data [String] :requestee_person_id Person being asked for evidence
#   @option data [String] :capability_stable_id stable UUID of the capability
#   @option data [Integer] :level_ordinal the level the evidence is about
#   @option data [String, nil] :message optional note to the requestee
#   @option data [String, nil] :due_at optional ISO8601 due date
#
class PersonDevelopment::Events::EvidenceRequested < RubyEventStore::Event
end
