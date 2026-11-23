# frozen_string_literal: true

# An account stopped being an Org Graph editor.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :tenant_user_id the account that held it
#   @option data [String] :person_id the account's person
#   @option data [String] :effective_on ISO 8601 date it took effect
#   @option data [String, nil] :removed_by_id person_id of the actor, nil when none
#
class AccountGrants::Events::OrgGraphEditorRemoved < RubyEventStore::Event
end
