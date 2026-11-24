# frozen_string_literal: true

# An account was linked to the person it signs in as.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :tenant_user_id the account
#   @option data [String] :person_id the person
#   @option data [String, nil] :linked_by_id person_id of the actor, nil when none
#   @option data [String, nil] :match how the person was found: "sign_in", "hris_email", "provisioned" or "admin"
#   @option data [Boolean] :already_held true when recorded from a link made before links were events
#
class AccountGrants::Events::AccountLinkedToPerson < RubyEventStore::Event
end
