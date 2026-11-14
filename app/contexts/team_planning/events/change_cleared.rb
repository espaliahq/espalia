# frozen_string_literal: true

# A scenario stopped overriding one facet of one subject, and follows its
# parent there again. Its earlier changes to that facet stay in the stream
# for history (3.10); nothing resolves through them.
#
# Reconcile (4.5) records "follow reality" as a clear.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :subject_id
#   @option data [String] :facet the second half of the cleared change's key, such as "rule:<name>"
#   @option data [String] :cleared_by_id person_id of the actor
#
class TeamPlanning::Events::ChangeCleared < RubyEventStore::Event
end
