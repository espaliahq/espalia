# frozen_string_literal: true

# A budget line's amount is pay
# ([#367](https://github.com/espaliahq/espalia/issues/367)), so a member
# without the see-pay right may not change, cut, undo, redo, clear or settle
# anything about a line that carries one. A line carries one when the
# organisation's line has an amount, or when any change along the scenario's
# chain gave it one, undone or not, so no undo or redo can bring one back.
# A line with a head count alone stays theirs to work on.
#
# This is the undo and clear gate. Whether a member may see or write a note
# on a budget-line change is the note gate, and is the facet's alone.
module TeamPlanning::LineMoney
  REFUSAL = "Changing this budget line needs the see-pay right."
  FACET = TeamPlanning::Events::BudgetLineSet.facet

  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String]
  # @return [Set<Array(String, String)>] the `[subject_id, facet]` keys of every line that carries an amount
  def self.priced_keys(aggregate, scenario_id)
    entries = aggregate.resolution_chain(scenario_id).flat_map { aggregate.log_of(it) }
    line_ids = entries.filter_map { it.data[:subject_id] if facet_of(it) == FACET }.uniq
    return Set.new if line_ids.empty?

    planned = entries.filter_map { it.data[:subject_id] if it.is_a?(TeamPlanning::Events::BudgetLineSet) && it.data[:amount].present? }
    tenant = ::BudgetLine.where(id: line_ids).where.not(amount: nil).pluck(:id)
    (planned + tenant).to_set { [ it, FACET ] }
  end

  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String]
  # @param subject_id [String, nil]
  # @param facet [String, nil]
  # @return [Boolean]
  def self.priced?(aggregate, scenario_id, subject_id, facet)
    return false unless facet == FACET

    priced_keys(aggregate, scenario_id).include?([ subject_id, facet ]) || ::BudgetLine.where(id: subject_id).where.not(amount: nil).exists?
  end

  def self.facet_of(entry) = entry.is_a?(TeamPlanning::Events::Change) ? entry.class.facet : entry.data[:facet]
  private_class_method :facet_of
end
