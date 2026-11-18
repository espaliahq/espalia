# frozen_string_literal: true

# Brings an archived plan back. Only an editor may.
class Operations::TeamPlanning::RestorePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Restore an archived Team Planning plan, so it takes changes and is checked against the organisation again. Refused unless the caller is one of its editors, when the plan isn't archived, or when it places units of a type removed since."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, archived }`
  def perform
    plan_id = plan_id!
    plan = refusing_bad_plans do
      handler.restore_plan(plan_id) do
        ::OrgGraph::Repository.new.lock_structure # so a type can't be removed between this check and the restore
        ensure_unit_types_remain!(plan_id)
      end
    end
    { plan_id:, archived: plan.archived? }
  end

  private

  # Removing a unit type waits only for live plans, so an archived plan can
  # still place units of a type that has gone since.
  def ensure_unit_types_remain!(plan_id)
    gone = ProjectionVersion.unless_rebuilding(::OrgGraph::Projections::Structure::PROJECTION_NAME) do
      TeamPlanningOverride.placing_plan_units.where(plan_id:)
                          .where("end_state ->> 'level_id' NOT IN (?)", OrgTaxonomyLevel.select("id::text"))
                          .count
    end
    return if gone.zero?

    raise Operations::Base::ParameterError,
          "This plan places #{gone} #{'unit'.pluralize(gone)} of a type that has been removed, so it can't be restored. " \
          "Delete it instead, or copy what you need into another plan"
  end
end
