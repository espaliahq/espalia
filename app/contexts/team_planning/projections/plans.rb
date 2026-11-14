# frozen_string_literal: true

# Synchronous projection of each live plan from the plan streams.
#
# Writes `team_planning_plans`, and nothing else writes it. A deleted plan's
# row goes.
#
class TeamPlanning::Projections::Plans
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/plans"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanRenamed, TeamPlanning::Events::PlanDeleted ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { TeamPlanningPlan.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      data = event.data
      case event
      when TeamPlanning::Events::PlanCreated
        TeamPlanningPlan.find_or_initialize_by(id: data[:plan_id])
          .update!(name: data[:name], base_on: data[:base_on], created_by_id: data[:created_by_id])
      when TeamPlanning::Events::PlanRenamed
        TeamPlanningPlan.where(id: data[:plan_id]).update_all(name: data[:name], updated_at: event.timestamp)
      when TeamPlanning::Events::PlanDeleted
        TeamPlanningPlan.where(id: data[:plan_id]).delete_all
      end
    end
  end
end
