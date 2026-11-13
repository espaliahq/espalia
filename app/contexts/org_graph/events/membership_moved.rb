# frozen_string_literal: true

# A person's membership moved from one unit to another, keeping its
# allocation, its role and when it began. A unit retired into one successor
# moves its members this way, and a split moves the people it names. It is
# one fact, so the person is never ended and added again.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :from_unit_id UUID of the unit they left
#   @option data [String] :unit_id UUID of the unit they are now in
#   @option data [Float, nil] :allocation carried over unchanged
#   @option data [String, nil] :role carried over unchanged
#   @option data [String] :provider who supplied the membership
#   @option data [String] :effective_on ISO date the move took effect
#   @option data [String, nil] :moved_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::MembershipMoved < RubyEventStore::Event
end
