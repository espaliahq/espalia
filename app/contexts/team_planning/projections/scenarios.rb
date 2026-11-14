# frozen_string_literal: true

# Synchronous projection of each live plan's scenarios from the plan streams.
#
# Writes `team_planning_scenarios`, and nothing else writes it. A plan's
# baseline row comes with `PlanCreated`; a deleted plan's scenarios go with
# it. Only a `then` scenario's end is held, so after every change to the tree
# the plan's starts, and its alternatives' ends, are worked out again.
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
        follow_tree(data[:plan_id], event)
      when TeamPlanning::Events::ScenarioPeriodSet
        TeamPlanningScenario.where(id: data[:scenario_id]).update_all(ends_on: data[:ends_on], updated_at: event.timestamp)
        follow_tree(data[:plan_id], event)
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

  # Sets every start from the tree, and each alternative's end from its parent.
  def follow_tree(plan_id, event)
    rows = TeamPlanningScenario.where(plan_id:).index_by(&:id)
    periods = {}
    period = lambda do |row|
      periods[row.id] ||=
        if row.baseline? then [ row.starts_on, nil ]
        elsif row.relation == "instead" then period.call(rows.fetch(row.parent_id))
        else
          parent = rows.fetch(row.parent_id)
          [ parent.baseline? ? parent.starts_on : period.call(parent).last + 1, row.ends_on ]
        end
    end
    rows.each_value do |row|
      starts_on, ends_on = period.call(row)
      next if row.baseline? || [ row.starts_on, row.ends_on ] == [ starts_on, ends_on ]

      row.update!(starts_on:, ends_on:, updated_at: event.timestamp)
    end
  end
end
