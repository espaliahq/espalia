# frozen_string_literal: true

# An account was made a planner, so it may create Team Planning plans.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :tenant_user_id the account that holds it
#   @option data [String] :person_id the account's person
#   @option data [String] :effective_on ISO 8601 date it took effect
#   @option data [String, nil] :added_by_id person_id of the actor, nil when none
#   @option data [Boolean] :already_held true when recorded from a grant held before it was an event
#
class AccountGrants::Events::PlannerAdded < RubyEventStore::Event
end
