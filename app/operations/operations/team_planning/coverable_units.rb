# frozen_string_literal: true

# The units a plan may cover, for the picker that starts or widens one
# ([#338](https://github.com/espaliahq/espalia/issues/338)). It reaches the
# whole organisation, so a planner who can't read the Org Graph can still
# choose. Unit names only, never people.
class Operations::TeamPlanning::CoverableUnits < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the live units a Team Planning plan may cover, in tree order (depth first, siblings by name), " \
              "each with its id, name, parent and depth: the ids team_planning_create_plan and " \
              "team_planning_set_plan_scope take as unit_ids. Without plan_id, refused unless the caller may create " \
              "a plan; with it, unless they are an editor of that plan."
  category :read
  approval :none

  parameter :plan_id, String

  def policy_check
    params[:plan_id] ? super : authorize(TeamPlanningPlan, :create?, policy_class: PlanPolicy)
  end

  # @return [Hash] `{ plan_id, units: [{ unit_id, name, parent_id, depth }] }`, with plan_id only when given
  def perform
    plan = plan!(:update?) if params[:plan_id]
    units = OrgUnit.live.pluck(:id, :name, :parent_id)
    live = units.to_set(&:first)
    @children = units.group_by { |_, _, parent_id| live.include?(parent_id) ? parent_id : nil }
                     .transform_values { it.sort_by { |id, name, _| [ name, id ] } }
    { **({ plan_id: plan.id } if plan), units: tree(nil, 0) }
  end

  private

  # Depth first, siblings by name, as the Org Graph's Units page orders them.
  def tree(parent_id, depth)
    @children.fetch(parent_id, []).flat_map do |id, name, _|
      [ { unit_id: id, name:, parent_id:, depth: }, *tree(id, depth + 1) ]
    end
  end
end
