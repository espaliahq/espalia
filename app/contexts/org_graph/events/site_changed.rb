# frozen_string_literal: true

# Where the person works, as the provider names it.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#   @option data [String, nil] :site the new site, or nil for none
#   @option data [String, nil] :country the new country, or nil for none
#
class OrgGraph::Events::SiteChanged < RubyEventStore::Event
end
