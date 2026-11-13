# frozen_string_literal: true

# A unit came to be supplied by another provider when its level was handed
# over. It is the same unit: its id, name, parent and members carry on.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String] :provider who supplies the unit from now on
#   @option data [String] :previous_provider
#   @option data [String, nil] :external_ref the new provider's reference; nil for Espalia
#   @option data [String, nil] :previous_external_ref
#   @option data [String] :effective_on ISO 8601 date
#   @option data [String, nil] :handed_over_by_id person_id of the actor
#
class OrgGraph::Events::UnitHandedOver < RubyEventStore::Event
end
