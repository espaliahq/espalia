# frozen_string_literal: true

# The person's manager.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#   @option data [String, nil] :manager_id person_id of the new manager, or nil for none
#
class OrgGraph::Events::ManagerChanged < RubyEventStore::Event
end
