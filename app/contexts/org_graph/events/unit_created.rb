# frozen_string_literal: true

# A unit came into being: a department, a team, a squad.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id stable UUID, kept through renames and moves
#   @option data [String] :name
#   @option data [String, nil] :parent_id the unit it sits beneath; nil at the top
#   @option data [String] :level_id the taxonomy level it belongs to
#   @option data [String] :provider who supplies the unit: "espalia" or an HRIS
#   @option data [String, nil] :external_ref the provider's own reference for a
#     mirrored unit, so a rename there is recognised as a rename; nil for Espalia's
#   @option data [String] :effective_on ISO 8601 date the unit took effect
#   @option data [String, nil] :created_by_id person_id of the actor
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::UnitCreated < RubyEventStore::Event
end
