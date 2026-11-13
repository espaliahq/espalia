# frozen_string_literal: true

# A unit stopped existing. Its id is never reused, and its history stays.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String] :provider who supplied the change
#   @option data [String] :effective_on ISO 8601 date the unit ended
#   @option data [String, nil] :retired_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#   @option data [String, nil] :succession_id the succession it was retired
#     through, if any. Its members then move to a successor instead of leaving.
#   @option data [Array<String>, nil] :successor_ids the units that carry on from it
#
class OrgGraph::Events::UnitRetired < RubyEventStore::Event
end
