# frozen_string_literal: true

# The tenant's names for its structure levels, top first. Redefining the
# taxonomy is a change like any other: each instance replaces the last.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [Array<Hash>] :levels ordered top first, each
#     `{ level_id:, name: }`; a level keeps its id through a rename
#   @option data [Array<Hash>] :previous_levels the levels it replaced, so the
#     history can say what a level used to be called; empty the first time
#   @option data [String, nil] :structure_unit_id the unit whose own structure
#     this defines, absent for the top structure (#494); its levels may say
#     `parent_level_ids:`, `top:` and `copied_from_level_id:`, and empty
#     levels withdraw it
#   @option data [String, nil] :copied_from "top", or the unit whose structure
#     a declared one copies; absent for a fresh one
#   @option data [Hash{String => String}, nil] :conversion each unit type held
#     beneath a declared structure's unit, to the type it became; the
#     UnitKindChanged events published with this one carry each change
#   @option data [String] :effective_on ISO 8601 date the taxonomy took effect
#   @option data [String, nil] :defined_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::TaxonomyDefined < RubyEventStore::Event
end
