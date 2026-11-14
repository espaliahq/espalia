# frozen_string_literal: true

# What the unit tools share: the scenario they name, resolved, and the checks
# the Org Graph would make, run against that scenario. An ancestor's later
# edit can still break them; the change resolves anyway, and a misfit marks it.
module Operations::TeamPlanning::UnitChange
  include Operations::TeamPlanning::PlanRead

  private

  # Refuses a viewer before the checks run, so a change reads the same to
  # them as to an outsider, whatever its parameters.
  #
  # @return [TeamPlanningPlan]
  # @raise [Operations::Base::ParameterError] "No such plan" unless the caller is an editor
  def editable_plan!
    plan = plan!
    return plan if PlanPolicy.new(context, plan).update?

    raise Operations::Base::ParameterError, "No such plan"
  end

  # @param plan [TeamPlanningPlan]
  # @return [String] the scenario_id parameter, or the baseline's id
  def scenario_for(plan) = scenario_id!(:scenario_id) || plan.id

  # @return [TeamPlanning::Baseline::Map] the scenario by id, with no names
  def resolved(plan, scenario_id)
    refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure }
  end

  # @return [TeamPlanning::Baseline::Unit]
  # @raise [Operations::Base::ParameterError] unless the unit is live in the scenario
  def live_unit!(map, unit_id)
    map.units.find { it.id == unit_id } || refuse!("There is no such live unit in this scenario")
  end

  # @return [Array<String>] the live units beneath a unit, at any depth
  def descendant_ids(map, unit_id)
    children = map.units.select { it.parent_id == unit_id }.map(&:id)
    children + children.flat_map { descendant_ids(map, it) }
  end

  # @return [Hash] a unit's name, parent and level, as a change carries them
  def as_it_stands(unit) = unit.to_h.slice(:name, :parent_id, :level_id)

  # @return [Array<String>] the taxonomy's level ids, top first
  def level_ids = @level_ids ||= OrgTaxonomyLevel.top_first.pluck(:id)

  def refuse!(message) = raise(Operations::Base::ParameterError, message)
end
