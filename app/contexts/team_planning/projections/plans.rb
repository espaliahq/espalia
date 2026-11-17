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
  CODE_VERSION = 2

  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanRenamed, TeamPlanning::Events::PlanRebased,
      TeamPlanning::Events::PlanScopeSet, TeamPlanning::Events::PlanArchived, TeamPlanning::Events::PlanRestored,
      TeamPlanning::Events::PlanDeleted ]
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
          .update!(name: data[:name], base_on: data[:base_on], base_known_at: base_known_at(data), created_by_id: data[:created_by_id],
                   created_at: event.timestamp, updated_at: event.timestamp)
      when TeamPlanning::Events::PlanRenamed
        TeamPlanningPlan.find_by(id: data[:plan_id])&.update!(name: data[:name], updated_at: event.timestamp)
      when TeamPlanning::Events::PlanRebased
        TeamPlanningPlan.where(id: data[:plan_id]).update_all(base_on: data[:base_on], base_known_at: base_known_at(data), updated_at: event.timestamp)
      when TeamPlanning::Events::PlanScopeSet
        TeamPlanningPlan.where(id: data[:plan_id]).update_all(scope_unit_ids: data[:unit_ids].presence, updated_at: event.timestamp)
      when TeamPlanning::Events::PlanArchived
        TeamPlanningPlan.where(id: data[:plan_id])
          .update_all(archived_on: archived_on(event), archived_known_at: end_of(archived_on(event), data[:time_zone]),
                      archived_by_id: data[:archived_by_id], updated_at: event.timestamp)
      when TeamPlanning::Events::PlanRestored
        TeamPlanningPlan.where(id: data[:plan_id]).update_all(archived_on: nil, archived_known_at: nil, archived_by_id: nil, updated_at: event.timestamp)
      when TeamPlanning::Events::PlanDeleted
        TeamPlanningPlan.where(id: data[:plan_id]).delete_all
      end
    end
  end

  private

  # Read from the event, never the clock, so a replay gives the same day.
  def archived_on(event) = event.data[:archived_on]&.then { Date.iso8601(it) } || event.timestamp.utc.to_date

  def base_known_at(data) = end_of(Date.iso8601(data[:base_on]) - 1, data[:time_zone])

  # In the zone the event recorded, so changing the tenant's zone later moves
  # no cut-off. An event from before zones leaves it empty, as rows written
  # before the column were, and {TeamPlanningPlan} reads the UTC end of day.
  def end_of(date, zone) = zone && date.in_time_zone(zone).end_of_day
end
