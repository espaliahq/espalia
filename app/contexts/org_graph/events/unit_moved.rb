# frozen_string_literal: true

# A unit now sits beneath a different parent.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :unit_id
#   @option data [String, nil] :parent_id the new parent; nil at the top
#   @option data [String, nil] :previous_parent_id
#   @option data [String] :provider who supplied the change
#   @option data [String] :effective_on ISO 8601 date the move took effect
#   @option data [String, nil] :moved_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#   @option data [String, nil] :changed_back_id the event this changes back, from "change it back"
#   @option data [Hash{String => String}, nil] :conversion on a move between structures (into a unit's own,
#     out of one into the organisation's, or between two), each type held in the moved units to the type it
#     takes; the UnitKindChanged events that follow carry it out ([#494](https://github.com/espaliahq/espalia/issues/494),
#     [#521](https://github.com/espaliahq/espalia/issues/521)). Absent on every move within one structure.
#   @option data [String, nil] :structure_left_id on a move between structures, the declaring unit of the
#     structure it left, nil for the organisation's; absent on moves written before
#     [#521](https://github.com/espaliahq/espalia/issues/521) named them
#   @option data [String, nil] :structure_joined_id likewise, the structure it joined
#
class OrgGraph::Events::UnitMoved < RubyEventStore::Event
end
