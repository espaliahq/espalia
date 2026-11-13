# frozen_string_literal: true

# A person who had not yet started has joined. The effective date is their start date.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#
class OrgGraph::Events::PersonJoined < RubyEventStore::Event
end
