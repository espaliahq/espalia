# frozen_string_literal: true

# Event emitted when manager-rating authority for a person on a framework is
# delegated to another person — e.g. when the report is seconded into another
# team and their reporting manager hands rating to someone closer to the work.
#
# The delegate may record manager ratings (each attributed to them via
# `rated_by_id` on `ManagerRated`) but may NOT start, complete, or record
# alignment — those stay with the reporting manager.
#
# Granting does not require an open cycle; the delegation persists across cycles
# until revoked or expired.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :delegate_person_id UUID of the Person receiving
#     rating authority
#   @option data [String] :granted_by_id UUID of the Person who granted it
#     (an ancestor manager or a tenant admin)
#   @option data [String, nil] :expires_at ISO 8601 timestamp after which the
#     delegation lapses, or nil for open-ended
#   @option data [String, nil] :reason optional note on why it was granted
#
class PersonDevelopment::Events::ManagerRatingDelegated < RubyEventStore::Event
end
