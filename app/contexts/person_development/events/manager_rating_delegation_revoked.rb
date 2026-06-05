# frozen_string_literal: true

# Event emitted when a manager-rating delegation is revoked.
#
# Non-destructive: ratings the delegate already recorded remain, attributed to
# them. Revoking only stops the delegate from recording further ratings.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :delegate_person_id UUID of the Person whose authority
#     is being revoked
#   @option data [String] :revoked_by_id UUID of the Person who revoked it
#     (an ancestor manager or a tenant admin)
#
class PersonDevelopment::Events::ManagerRatingDelegationRevoked < RubyEventStore::Event
end
