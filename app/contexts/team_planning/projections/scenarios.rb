# frozen_string_literal: true

# Synchronous projection of each live plan's scenarios from the plan streams.
#
# Writes `team_planning_scenarios`, and nothing else writes it. A plan's
# baseline row comes with `PlanCreated`; a deleted plan's scenarios go with
# it. A fork carries its own period. Only a `then` scenario's end is held, so
# when one moves the plan's starts, and its alternatives' ends, are worked out
# again.
#
class TeamPlanning::Projections::Scenarios
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/scenarios"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  BASELINE_NAME = "Baseline"

  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanDeleted, TeamPlanning::Events::ScenarioForked,
      TeamPlanning::Events::ScenarioPeriodSet, TeamPlanning::Events::ScenarioRemoved ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { TeamPlanningScenario.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      data = event.data
      case event
      when TeamPlanning::Events::PlanCreated
        write(data[:plan_id], event, plan_id: data[:plan_id], name: BASELINE_NAME, starts_on: data[:base_on])
      when TeamPlanning::Events::PlanDeleted then TeamPlanningScenario.where(plan_id: data[:plan_id]).delete_all
      when TeamPlanning::Events::ScenarioForked
        write(data[:scenario_id], event, **data.slice(:plan_id, :parent_id, :relation, :name, :starts_on, :ends_on, :forked_by_id))
      when TeamPlanning::Events::ScenarioPeriodSet
        follow_tree(data[:plan_id], event, moved: data[:scenario_id], ends_on: Date.iso8601(data[:ends_on]))
      when TeamPlanning::Events::ScenarioRemoved then TeamPlanningScenario.where(id: data[:scenario_id]).delete_all
      end
    end
  end

  private

  def write(id, event, **attributes)
    row = TeamPlanningScenario.find_or_initialize_by(id:)
    row.created_at ||= event.timestamp
    row.update!(**attributes, updated_at: event.timestamp)
  end

  # Moves one step's end, then sets every start from the tree and each
  # alternative's end from its parent. A row whose parent row is missing, as in
  # a plan created before this projection was rebuilt, keeps its own period.
  def follow_tree(plan_id, event, moved:, ends_on:)
    rows = TeamPlanningScenario.where(plan_id:).index_by(&:id)
    rows[moved]&.ends_on = ends_on
    periods = {}
    period = lambda do |row|
      periods[row.id] ||=
        if row.baseline? || !rows.key?(row.parent_id) then [ row.starts_on, row.ends_on ]
        elsif row.relation == "instead" then period.call(rows[row.parent_id])
        else
          parent = rows[row.parent_id]
          [ parent.baseline? ? parent.starts_on : period.call(parent).last + 1, row.ends_on ]
        end
    end
    rows.each_value do |row|
      row.starts_on, row.ends_on = period.call(row)
      row.update!(updated_at: event.timestamp) if row.changed?
    end
  end
end
