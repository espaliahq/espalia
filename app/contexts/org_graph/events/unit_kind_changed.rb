# frozen_string_literal: true

# A unit is now of a different kind, such as a Team that becomes a Squad. Its
# id, name, place, owners and members stay as they were.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String] :level_id the new kind
#   @option data [String] :previous_level_id
#   @option data [String] :provider who supplied the change
#   @option data [String] :effective_on ISO 8601 date the change took effect
#   @option data [String, nil] :kind_changed_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#   @option data [String, nil] :changed_back_id the event this changes back, from "change it back"
#
class OrgGraph::Events::UnitKindChanged < RubyEventStore::Event
end
