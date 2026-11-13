# frozen_string_literal: true

# A unit now sits beneath a different parent.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String, nil] :parent_id the new parent; nil at the top
#   @option data [String, nil] :previous_parent_id
#   @option data [String] :provider who supplied the change
#   @option data [String] :effective_on ISO 8601 date the move took effect
#   @option data [String, nil] :moved_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::UnitMoved < RubyEventStore::Event
end
