# frozen_string_literal: true

# Emitted when the requester (or an admin) cancels a still-pending evidence
# request — e.g. it's no longer needed or was sent in error.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :request_id UUID of the request being cancelled
#   @option data [String] :cancelled_by_id Person who cancelled
#
class PersonDevelopment::Events::EvidenceRequestCancelled < RubyEventStore::Event
end
