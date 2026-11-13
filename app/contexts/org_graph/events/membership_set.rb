# frozen_string_literal: true

# A person is a member of a unit, or their terms there changed: the share of
# their time it has, and the role they play in it. A person can be a member of
# several units, one membership each.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :unit_id UUID of the unit
#   @option data [Float, nil] :allocation the share of the person's time, greater
#     than 0 and at most 1; nil when the provider states none
#   @option data [String, nil] :role the role played in the unit, as the provider names it
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#   @option data [String, nil] :set_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::MembershipSet < RubyEventStore::Event
end
