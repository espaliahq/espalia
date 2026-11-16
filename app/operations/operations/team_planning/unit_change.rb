# frozen_string_literal: true

# What the unit tools share: the write, with the checks the Org Graph would
# make run under the plan's lock against the scenario as it then resolves. An
# ancestor's later edit can still break them; the change resolves anyway, and
# a misfit marks it.
module Operations::TeamPlanning::UnitChange
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::WithinScope

  private

  # @return [String] the scenario_id parameter, or the baseline's id
  def scenario_for = scenario_id!(:scenario_id) || plan_id!

  # Stores the changes the block returns in one write. The block runs once the
  # caller may edit the plan, so a viewer or outsider gets "No such plan"
  # before any check.
  #
  # @yieldparam map [TeamPlanning::Baseline::Map] the scenario by id, with no names
  # @yieldreturn [Array<Hash>] each `{ kind:, scenario_id:, subject_id:, end_state: }`; each carries the note a tool
  #   takes through {Operations::TeamPlanning::ChangeWrite}
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  def set_unit_changes!(scenario_id)
    refusing_bad_plans do
      handler.set_changes(plan_id!) do
        map = ::TeamPlanning::Resolution.new(context:, plan: plan!, scenario_id:).structure
        changes = yield(map)
        changes.each { place_within_scope!(map, it[:kind], it[:subject_id], it[:end_state]) } if map.scope_ids
        changes.map { { note: params[:note], **it } }
      end
    end
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
