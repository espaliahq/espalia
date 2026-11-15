# frozen_string_literal: true

# A plan member may now see pay in the plan: band ranges now, and the actual
# pay the plan holds once it holds any. A tenant admin restoring a locked-out
# plan grants it too, without being a member.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :person_id the member
#   @option data [String] :granted_by_id person_id of the actor
#   @option data [Boolean] :recovery true when a tenant admin restored the plan
#
class TeamPlanning::Events::SeePayGranted < RubyEventStore::Event
end
