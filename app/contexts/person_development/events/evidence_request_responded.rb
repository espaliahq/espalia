# frozen_string_literal: true

# Emitted when a requestee fulfils an evidence request by providing evidence.
# The evidence item itself is recorded via EvidenceRecorded (source "peer");
# this event links that item to the request and moves it to "responded".
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :request_id UUID of the request being fulfilled
#   @option data [String] :evidence_id UUID of the evidence item provided
#   @option data [String] :responded_by_id Person who provided the evidence
#
class PersonDevelopment::Events::EvidenceRequestResponded < RubyEventStore::Event
end
