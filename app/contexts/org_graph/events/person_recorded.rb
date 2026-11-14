# frozen_string_literal: true

# The first time the Org Graph sees a person, with the facts as they stood. History starts here.
#
# Like every Org Graph event, it holds identity by reference only: no name,
# email or external id.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider who supplied the fact (see {OrgGraph::PersonAggregate::PROVIDERS})
#   @option data [String] :effective_on ISO date the fact took effect
#   @option data [String] :employment_status "pending" (not yet started), "employed" or "left"
#   @option data [String, nil] :started_on ISO date the person started
#   @option data [String, nil] :left_on ISO date the person left
#   @option data [String] :left_on_source where a leaving date worked out from
#     the person's row came from (see {OrgGraph::PersonAggregate::LEFT_ON_SOURCES});
#     absent when the provider supplied the date
#   @option data [String, nil] :title job title as the provider names it
#   @option data [String, nil] :level level as the provider names it, before any framework mapping
#   @option data [String, nil] :manager_id person_id of their manager
#   @option data [String, nil] :cost_centre cost centre as the provider names it
#   @option data [String, nil] :site site as the provider names it
#   @option data [String, nil] :country country as the provider names it
#   @option data [Float, nil] :fte full-time equivalent, greater than 0 and at most 1
#   @option data [String, nil] :employment_type employment type as the provider names it
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::PersonRecorded < RubyEventStore::Event
end
