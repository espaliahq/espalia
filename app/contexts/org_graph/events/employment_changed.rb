# frozen_string_literal: true

# The person's FTE and employment type.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#   @option data [Float, nil] :fte full-time equivalent, greater than 0 and at most 1
#   @option data [String, nil] :employment_type employment type as the provider names it
#
class OrgGraph::Events::EmploymentChanged < RubyEventStore::Event
end
