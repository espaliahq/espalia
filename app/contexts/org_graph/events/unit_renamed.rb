# frozen_string_literal: true

# A unit took a new name. It is the same unit: its id does not change.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String] :name the new name
#   @option data [String] :previous_name so the history can read "was X"
#   @option data [String] :provider who supplied the change
#   @option data [String] :effective_on ISO 8601 date the name took effect
#   @option data [String, nil] :renamed_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::UnitRenamed < RubyEventStore::Event
end
