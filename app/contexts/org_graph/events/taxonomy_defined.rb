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
#   @option data [String] :effective_on ISO 8601 date the taxonomy took effect
#   @option data [String, nil] :defined_by_id person_id of the actor
#   @option data [String, nil] :plan_id the plan it was applied from
#   @option data [String, nil] :plan_change_id the plan change it was applied from
#
class OrgGraph::Events::TaxonomyDefined < RubyEventStore::Event
end
