# frozen_string_literal: true

# A person was named an owner of a unit. Ownership is always stated, never
# derived from reporting lines or a role in the unit.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String] :person_id the owner
#   @option data [String] :effective_on ISO 8601 date it took effect
#   @option data [String, nil] :added_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::UnitOwnerAdded < RubyEventStore::Event
end
