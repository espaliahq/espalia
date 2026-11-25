# frozen_string_literal: true

# An account was unlinked from its person.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :tenant_user_id the account
#   @option data [String] :effective_on ISO 8601 date it took effect
#   @option data [String] :person_id the person it was linked to
#   @option data [String, nil] :unlinked_by_id person_id of the actor, nil when none
#   @option data [String] :reason "forgotten", "admin", "account_removed" (its row was destroyed) or "cleared" (reconcile found the link gone)
#
class AccountGrants::Events::AccountUnlinkedFromPerson < RubyEventStore::Event
end
