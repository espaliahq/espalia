# frozen_string_literal: true

# Emitted when a requestee declines an evidence request, optionally with a
# reason for the requester.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :request_id UUID of the request being declined
#   @option data [String] :declined_by_id Person who declined
#   @option data [String, nil] :reason optional explanation for the requester
#
class PersonDevelopment::Events::EvidenceRequestDeclined < RubyEventStore::Event
end
