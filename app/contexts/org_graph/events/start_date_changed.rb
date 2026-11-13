# frozen_string_literal: true

# The date a person started, as the provider holds it, for someone already
# employed. Joining is {OrgGraph::Events::PersonJoined}; this corrects or
# supplies the start date without moving their status.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date: the start date itself
#   @option data [String] :started_on the same date, named for readers
#
class OrgGraph::Events::StartDateChanged < RubyEventStore::Event
end
