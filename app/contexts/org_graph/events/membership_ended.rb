# frozen_string_literal: true

# A person is no longer a member of a unit. Their other memberships stand.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :unit_id UUID of the unit
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the membership ended
#   @option data [String, nil] :ended_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#   @option data [String, nil] :changed_back_id the event this changes back, from "change it back"
#
class OrgGraph::Events::MembershipEnded < RubyEventStore::Event
end
