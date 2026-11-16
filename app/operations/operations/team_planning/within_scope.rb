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
