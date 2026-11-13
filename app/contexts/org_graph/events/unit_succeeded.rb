# frozen_string_literal: true

# One or more units carry on from one or more others: a split (one into
# several), a merge (several into one) or a replacement (one for one).
# Someone always states it; the Org Graph never infers it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :succession_id UUID for this succession
#   @option data [Array<String>] :predecessor_ids the units that came before
#   @option data [Array<String>] :successor_ids the units that carry on from them
#   @option data [String] :effective_on ISO 8601 date it took effect
#   @option data [String, nil] :stated_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::UnitSucceeded < RubyEventStore::Event
end
