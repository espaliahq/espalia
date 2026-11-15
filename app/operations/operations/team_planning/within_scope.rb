# frozen_string_literal: true

# What keeps a scoped plan's changes about the people it covers, for the
# writes that set a change and for a redo, which can restore one.
module Operations::TeamPlanning::WithinScope
  private

  # A scoped plan holds changes about the people it covers, and about someone
  # outside only through the change that places them in a covered unit
  # ([#338](https://github.com/espaliahq/espalia/issues/338)). The refusal
  # says nothing about the person the plan can't show.
  def within_scope!(plan, kind, subject_id, end_state)
    record = TeamPlanningPlan.find(plan.plan_id)
    return if record.scope_unit_ids.blank?

    map = ::TeamPlanning::Resolution.new(context:, plan: record, scenario_id: scenario_id!(:scenario_id)).structure(plan)
    return unless map.outside_ids.include?(subject_id)
    return if kind == ::TeamPlanning::Events::AssignmentSet && brings_in?(map, end_state)

    raise Operations::Base::ParameterError, "This person is outside the units this plan covers. Place them in one of its units first."
  end

  def brings_in?(map, end_state)
    positions = map.positions.to_set(&:id)
    units = map.known_unit_ids
    Array(end_state[:placements]).any? do |placement|
      placement = placement.to_h.symbolize_keys
      units.include?(placement[:unit_id]) || positions.include?(placement[:position_id])
    end
  end
end
