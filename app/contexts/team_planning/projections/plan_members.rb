# frozen_string_literal: true

# Synchronous projection of who is in each live plan, from the plan streams.
#
# Writes `team_planning_plan_members`, and nothing else writes it. A plan's
# creator is its first editor and its first holder of the see-pay right; a
# deleted plan's members go with it. A member re-added after removal holds no
# right until it is granted again.
#
class TeamPlanning::Projections::PlanMembers
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/plan_members"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 2

  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanMemberAdded,
      TeamPlanning::Events::PlanMemberRemoved, TeamPlanning::Events::PlanDeleted,
      TeamPlanning::Events::SeePayGranted, TeamPlanning::Events::SeePayWithdrawn ]
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
      when TeamPlanning::Events::PlanCreated
        member(data[:plan_id], data[:created_by_id], "editor", event)
        see_pay(data[:plan_id], data[:created_by_id], event, granted_by_id: data[:created_by_id])
      when TeamPlanning::Events::PlanMemberAdded then member(data[:plan_id], data[:person_id], data[:role], event)
      when TeamPlanning::Events::PlanMemberRemoved
        TeamPlanningPlanMember.where(plan_id: data[:plan_id], person_id: data[:person_id]).delete_all
      when TeamPlanning::Events::PlanDeleted then TeamPlanningPlanMember.where(plan_id: data[:plan_id]).delete_all
      when TeamPlanning::Events::SeePayGranted
        see_pay(data[:plan_id], data[:person_id], event, granted_by_id: data[:granted_by_id], recovery: data[:recovery])
      when TeamPlanning::Events::SeePayWithdrawn then see_pay(data[:plan_id], data[:person_id], event, granted_by_id: nil)
      end
    end
  end

  private

  def member(plan_id, person_id, role, event)
    row = TeamPlanningPlanMember.find_or_initialize_by(plan_id:, person_id:)
    row.created_at ||= event.timestamp
    row.update!(role:, updated_at: event.timestamp)
  end

  def see_pay(plan_id, person_id, event, granted_by_id:, recovery: false)
    granted = !granted_by_id.nil?
    TeamPlanningPlanMember.where(plan_id:, person_id:).update_all(
      see_pay: granted, see_pay_granted_by_id: granted_by_id, see_pay_granted_at: (event.timestamp if granted),
      see_pay_by_recovery: granted && recovery == true, updated_at: event.timestamp
    )
  end
end
