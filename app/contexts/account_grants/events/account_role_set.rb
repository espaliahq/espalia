# frozen_string_literal: true

# An account's role in the tenant was set: a member, or an admin.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :tenant_user_id the account
#   @option data [String, nil] :person_id the account's person
#   @option data [String] :role "member" or "admin"
#   @option data [String] :effective_on ISO 8601 date it took effect
#   @option data [String, nil] :set_by_id person_id of the actor, nil when none
#   @option data [Boolean] :already_held true when recorded from a role held before roles were events
#
class AccountGrants::Events::AccountRoleSet < RubyEventStore::Event
end
