# frozen_string_literal: true

# An account that held a role was destroyed or forgotten, so it holds none.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :tenant_user_id the account
#   @option data [String, nil] :person_id the account's person
#   @option data [String] :effective_on ISO 8601 date it took effect
#
class AccountGrants::Events::AccountRoleRemoved < RubyEventStore::Event
end
