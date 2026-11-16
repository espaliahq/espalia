# frozen_string_literal: true

# What keeps a scoped plan's changes about the people, units and positions it
# covers, for the writes that set a change and for an undo or redo, which can
# restore one ([#365](https://github.com/espaliahq/espalia/issues/365)).
module Operations::TeamPlanning::WithinScope
  PLACING = { ::TeamPlanning::Events::UnitSet => "unit", ::TeamPlanning::Events::PositionSet => "position" }.freeze

  private

  # A scoped plan holds changes about the people it covers, and about someone
  # outside only through the change that places them in a covered unit
  # ([#338](https://github.com/espaliahq/espalia/issues/338)). The refusal
  # says nothing about the person the plan can't show.
  def within_scope!(plan, kind, subject_id, end_state, scenario_id: scenario_id!(:scenario_id))
    record = TeamPlanningPlan.find(plan.plan_id)
    return if record.scope_unit_ids.blank?

    resolution = ::TeamPlanning::Resolution.new(context:, plan: record, scenario_id:)
    map, winning = resolution.resolved(plan)
    place_within_scope!(map, kind, subject_id, end_state, closed_units: resolution.closed_position_units(plan, winning))
    lines_within_scope!(plan, map, scenario_id, kind, subject_id, end_state)
    return unless map.outside_ids.include?(subject_id)
    return if kind == ::TeamPlanning::Events::AssignmentSet && brings_in?(map, end_state)

    raise Operations::Base::ParameterError, "This person is outside the units this plan covers. Place them in one of its units first."
  end

  # A unit or position the plan doesn't cover takes a change only from the one
  # that places it under a covered unit, and no change may place one outside.
  # A closed position is off the map, so its unit comes from `closed_units`.
  def place_within_scope!(map, kind, subject_id, end_state, closed_units: {})
    if (noun = PLACING[kind])
      return if lands_inside?(map, kind, subject_id, end_state)
    elsif map.cut_ids.include?(subject_id)
      noun = map.cut_unit_ids.include?(subject_id) ? "unit" : "position"
    elsif closed_units.key?(subject_id) && !map.known_unit_ids.include?(closed_units[subject_id])
      noun = "position"
    elsif kind == ::TeamPlanning::Events::UnitSuccessionSet && !kind.refers_to(end_state.to_h.symbolize_keys).all? { map.known_unit_ids.include?(it) }
      noun = "unit"
    else
      return
    end
    raise Operations::Base::ParameterError, "This #{noun} is outside the units this plan covers. Place it in one of its units first."
  end

  # A scoped plan holds only the budget lines its seats can draw on
  # ([#378](https://github.com/espaliahq/espalia/issues/378)), so no change
  # may name, add or draw on one outside them. A line outside reads as one that
  # doesn't exist; only a cost centre the caller gave is refused as outside.
  def lines_within_scope!(plan, map, scenario_id, kind, subject_id, end_state)
    end_state = end_state.to_h.symbolize_keys
    ids = if kind.in?([ ::TeamPlanning::Events::BudgetLineSet, ::TeamPlanning::Events::BudgetLineCut ]) then [ subject_id ]
    elsif kind == ::TeamPlanning::Events::PositionFundingSet then Array(end_state[:draws]).map { it.to_h.symbolize_keys[:budget_line_id] }
    else return
    end
    if ids.any? { line_outside?(plan, map, scenario_id, it) }
      raise Operations::Base::ParameterError, Operations::TeamPlanning::BudgetLineWrite::NO_SUCH_LINE
    end
    return unless kind == ::TeamPlanning::Events::BudgetLineSet && !map.holds_cost_centre?(end_state[:cost_centre])

    raise Operations::Base::ParameterError, "This budget line is outside the cost centres this plan covers. Widen the plan's units first."
  end

  # A line is judged by the cost centre the scenario last gave it, even after a
  # cut, so a later edit to the organisation's line never changes what the plan
  # holds. A line the scenario never set is judged as the map holds it.
  def line_outside?(plan, map, scenario_id, line_id)
    set = plan.resolution_chain(scenario_id).flat_map { plan.changes_in(it) }
              .reverse.find { it.is_a?(::TeamPlanning::Events::BudgetLineSet) && it.data[:subject_id] == line_id }
    return !map.holds_cost_centre?(set.data[:cost_centre]) if set
    return map.outside_line?(line_id) if map.line?(line_id)

    !map.holds_cost_centre?(::BudgetLine.find_by(id: line_id)&.cost_centre)
  end

  def lands_inside?(map, kind, subject_id, end_state)
    return true if kind == ::TeamPlanning::Events::UnitSet && map.scope_ids.include?(subject_id)

    kind.refers_to(end_state.to_h.symbolize_keys).any? { map.known_unit_ids.include?(it) }
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
