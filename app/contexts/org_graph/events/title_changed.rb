# frozen_string_literal: true

# The person's job title, as the provider names it.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#   @option data [String, nil] :title the new title, or nil when the provider has none
#
class OrgGraph::Events::TitleChanged < RubyEventStore::Event
end
