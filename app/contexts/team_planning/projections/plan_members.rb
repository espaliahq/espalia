# frozen_string_literal: true

# Synchronous projection of who is in each live plan, from the plan streams.
#
# Writes `team_planning_plan_members`, and nothing else writes it. A plan's
# creator is its first editor; a deleted plan's members go with it.
#
class TeamPlanning::Projections::PlanMembers
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/plan_members"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanMemberAdded,
      TeamPlanning::Events::PlanMemberRemoved, TeamPlanning::Events::PlanDeleted ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { TeamPlanningPlanMember.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      data = event.data
      case event
      when TeamPlanning::Events::PlanCreated then member(data[:plan_id], data[:created_by_id], "editor", event)
      when TeamPlanning::Events::PlanMemberAdded then member(data[:plan_id], data[:person_id], data[:role], event)
      when TeamPlanning::Events::PlanMemberRemoved
        TeamPlanningPlanMember.where(plan_id: data[:plan_id], person_id: data[:person_id]).delete_all
      when TeamPlanning::Events::PlanDeleted then TeamPlanningPlanMember.where(plan_id: data[:plan_id]).delete_all
      end
    end
  end

  private

  def member(plan_id, person_id, role, event)
    row = TeamPlanningPlanMember.find_or_initialize_by(plan_id:, person_id:)
    row.created_at ||= event.timestamp
    row.update!(role:, updated_at: event.timestamp)
  end
end
