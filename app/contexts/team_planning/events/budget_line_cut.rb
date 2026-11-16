# frozen_string_literal: true

# A budget line a scenario cuts. It shares {BudgetLineSet}'s facet, so
# whichever came last wins: a later BudgetLineSet brings the line back. A cut
# of a tenant line the tenant later removes reads as orphaned.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the line's id
#   @option data [Boolean] :tenant_line whether it cuts one of the tenant's lines
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::BudgetLineCut < TeamPlanning::Events::Change
  # @return [String]
  def self.facet = TeamPlanning::Events::BudgetLineSet.facet

  # @param end_state [Hash] `{ tenant_line: }`
  # @return [Hash]
  def self.end_state(end_state) = { tenant_line: end_state.to_h.symbolize_keys[:tenant_line] == true }

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    id = data[:subject_id]
    if map.line?(id)
      return map.with(budget_lines: map.budget_lines.reject { it.id == id }, outside_lines: map.outside_lines.reject { it.id == id })
    end

    data[:tenant_line] ? map.with(orphaned_lines: map.orphaned_lines.merge(id => "cut")) : map
  end
end
