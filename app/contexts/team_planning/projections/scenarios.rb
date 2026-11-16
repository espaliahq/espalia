# frozen_string_literal: true

# Synchronous projection of each live plan's scenarios from the plan streams.
#
# Writes `team_planning_scenarios`, and nothing else writes it. A plan's
# baseline row comes with `PlanCreated`; a deleted plan's scenarios go with
# it. A fork carries its own period, and a split puts the agreed part in the
# original's place with the original on it. Only a `then` scenario's end, and a
# first step's start, are held, and the last step on a line may have no end; a
# fork after it closes it the day before the new step starts. When an end or
# a first start moves, the plan's starts, and its alternatives' ends, are
# worked out again. Names and descriptions are held sealed, as the events hold
# them.
#
# A removed scenario's row moves to `team_planning_removed_scenarios`, which
# it also writes alone, with its name still sealed and its period as it stood
# ([#340](https://github.com/espaliahq/espalia/issues/340)). Version 3 adds
# that table, which past removals fill, so its deploy needs
# `REBUILD_ON_DEPLOY=team_planning/scenarios`.
#
# A closed step holds the UTC day it was closed and who closed it, until it
# is reopened. Closing is new, so it needs no rebuild.
#
class TeamPlanning::Projections::Scenarios
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/scenarios"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 3

  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanDeleted, TeamPlanning::Events::ScenarioForked,
      TeamPlanning::Events::ScenarioRenamed, TeamPlanning::Events::ScenarioDescribed,
      TeamPlanning::Events::ScenarioPeriodSet, TeamPlanning::Events::ScenarioRemoved, TeamPlanning::Events::PlanRebased,
      TeamPlanning::Events::ScenarioSplit, TeamPlanning::Events::StepClosed, TeamPlanning::Events::StepReopened ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      TeamPlanningScenario.where(tenant_id: tenant.id).delete_all
      TeamPlanningRemovedScenario.where(tenant_id: tenant.id).delete_all
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      data = event.data
      case event
      when TeamPlanning::Events::PlanCreated
        write(data[:plan_id], event, plan_id: data[:plan_id], starts_on: data[:base_on])
      when TeamPlanning::Events::PlanDeleted
        TeamPlanningScenario.where(plan_id: data[:plan_id]).delete_all
        TeamPlanningRemovedScenario.where(plan_id: data[:plan_id]).delete_all
      when TeamPlanning::Events::ScenarioForked
        if data[:closes_scenario_id]
          follow_tree(data[:plan_id], event) { it[data[:closes_scenario_id]]&.ends_on = Date.iso8601(data[:closes_on]) }
        end
        write(data[:scenario_id], event, **data.slice(:plan_id, :parent_id, :relation, :name, :starts_on, :ends_on, :forked_by_id))
      when TeamPlanning::Events::ScenarioRenamed
        TeamPlanningScenario.find_by(id: data[:scenario_id])&.update!(name: data[:name], updated_at: event.timestamp)
      when TeamPlanning::Events::ScenarioDescribed
        TeamPlanningScenario.find_by(id: data[:scenario_id])&.update!(description: data[:description], updated_at: event.timestamp)
      when TeamPlanning::Events::ScenarioPeriodSet
        follow_tree(data[:plan_id], event) { it[data[:scenario_id]]&.assign_attributes(data.slice(:starts_on, :ends_on)) }
      when TeamPlanning::Events::PlanRebased
        write(data[:plan_id], event, plan_id: data[:plan_id], starts_on: data[:base_on])
        follow_tree(data[:plan_id], event) { it[data[:plan_id]].starts_on = Date.iso8601(data[:base_on]) }
      when TeamPlanning::Events::ScenarioSplit then split(event)
      when TeamPlanning::Events::ScenarioRemoved then remove(event)
      when TeamPlanning::Events::StepClosed
        TeamPlanningScenario.find_by(id: data[:scenario_id])
                            &.update!(closed_on: event.timestamp.utc.to_date, closed_by_id: data[:closed_by_id], updated_at: event.timestamp)
      when TeamPlanning::Events::StepReopened
        TeamPlanningScenario.find_by(id: data[:scenario_id])&.update!(closed_on: nil, closed_by_id: nil, updated_at: event.timestamp)
      end
    end
  end

  private

  def remove(event)
    data = event.data
    row = TeamPlanningScenario.find_by(id: data[:scenario_id]) or return

    removed = TeamPlanningRemovedScenario.find_or_initialize_by(id: row.id)
    removed.created_at ||= event.timestamp
    removed.update!(**row.slice(:plan_id, :name, :relation, :starts_on, :ends_on).symbolize_keys,
                    removed_by_id: data[:removed_by_id], removed_at: event.timestamp, updated_at: event.timestamp)
    row.delete
  end

  def split(event)
    data = event.data
    original = TeamPlanningScenario.find_by(id: data[:scenario_id]) or return
    return if TeamPlanningScenario.exists?(id: data[:agreed_id])

    write(data[:agreed_id], event, **original.slice(:plan_id, :parent_id, :relation, :starts_on, :ends_on).symbolize_keys,
                                   name: data[:name], forked_by_id: data[:split_by_id])
    original.update!(parent_id: data[:agreed_id], relation: "on", updated_at: event.timestamp)
  end

  def write(id, event, **attributes)
    row = TeamPlanningScenario.find_or_initialize_by(id:)
    row.created_at ||= event.timestamp
    row.update!(**attributes, updated_at: event.timestamp)
  end

  # Moves a step's period or the baseline's start, as the block does, then sets
  # every start from the tree and each alternative's end from its parent. A
  # first step keeps its own start until the base passes it; a base only moves
  # forward, so its row's start is all it needs. A row whose parent row is
  # missing, as in a plan created before this projection was rebuilt, keeps
  # its own period.
  def follow_tree(plan_id, event)
    rows = TeamPlanningScenario.where(plan_id:).index_by(&:id)
    yield rows
    periods = {}
    period = lambda do |row|
      periods[row.id] ||=
        if row.baseline? || !rows.key?(row.parent_id) then [ row.starts_on, row.ends_on ]
        else
          case row.relation
          in "instead" | "on" then period.call(rows[row.parent_id])
          in "then"
            parent = rows[row.parent_id]
            [ parent.baseline? ? [ row.starts_on, parent.starts_on ].max : period.call(parent).last + 1, row.ends_on ]
          end
        end
    end
    rows.each_value do |row|
      row.starts_on, row.ends_on = period.call(row)
      row.update!(updated_at: event.timestamp) if row.changed?
    end
  end
end
