# frozen_string_literal: true

# A leaver's identifiers have been erased from their `people` row. Nothing
# about the person changes in the Org Graph, and no later event follows.
#
# Like every Org Graph event, it holds identity by reference only.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :person_id UUID of the person
#   @option data [String] :provider always "espalia"
#   @option data [String] :effective_on ISO date the identifiers were erased
#   @option data [String] :reason "retention" when their period ended, "request" when an admin asked first
#   @option data [Integer, nil] :retention_years the tenant's period at the time, nil for never
#   @option data [String, nil] :requested_by_id the tenant user who asked, for a request
#
class OrgGraph::Events::PersonForgotten < RubyEventStore::Event
end
