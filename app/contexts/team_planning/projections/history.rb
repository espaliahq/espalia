# frozen_string_literal: true

# Synchronous projection of each scenario's history: every change, pin and
# clear it made, every undo and redo of one, and every rewrite of a note, in
# the order made, read through {TeamPlanning::ChangeEntry}. The baseline's
# history also holds each update to today.
#
# Writes `team_planning_history_entries`, and nothing else writes it. An undo
# marks the entry it reverses as undone and a redo lifts the mark; both stay
# as entries of their own. A split moves the entries of its subjects and facets
# to the agreed part, in their order, and a move, or an undo or redo of one,
# takes the entries it moved to the step they now stand in. A removed scenario
# or a deleted plan takes its entries with it; the stream keeps them. It hears
# every kind in {TeamPlanning::ChangeKinds}.
#
# Production already holds changes, pins and clears, so the deploy that ships
# it needs `REBUILD_ON_DEPLOY=team_planning/history`.
#
class TeamPlanning::Projections::History
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/history"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    TeamPlanning::ChangeKinds.all + [
      TeamPlanning::Events::ChangePinned, TeamPlanning::Events::ChangeCleared, TeamPlanning::Events::ChangeUndone,
      TeamPlanning::Events::ChangeRedone, TeamPlanning::Events::ChangeNoted, TeamPlanning::Events::PlanRebased,
      TeamPlanning::Events::ChangeMoved,
      TeamPlanning::Events::PlanArchived, TeamPlanning::Events::PlanRestored, TeamPlanning::Events::ScenarioRemoved, TeamPlanning::Events::ScenarioSplit,
      TeamPlanning::Events::PlanDeleted
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { TeamPlanningHistoryEntry.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      case event
      when TeamPlanning::Events::ScenarioRemoved then TeamPlanningHistoryEntry.where(scenario_id: event.data[:scenario_id]).delete_all
      when TeamPlanning::Events::PlanDeleted then TeamPlanningHistoryEntry.where(plan_id: event.data[:plan_id]).delete_all
      when TeamPlanning::Events::ScenarioSplit then split(event.data)
      when TeamPlanning::Events::ChangeMoved
        rehome(event.data[:moved_event_ids], from: event.data[:scenario_id], to: event.data[:to_scenario_id]) unless recorded?(event)
        record(TeamPlanning::ChangeEntry.from(event))
      else
        from, to = TeamPlanning::ChangeEntry.moving(event)
        rehome(event.data[:moved_event_ids], from:, to:, before: event.data[:redone_event_id] || event.data[:moves_before_id]) if to && !recorded?(event)
        record(TeamPlanning::ChangeEntry.from(event))
      end
    end
  end

  private

  def split(data)
    keys = data[:keys].map(&:to_a).to_set
    moving = TeamPlanningHistoryEntry.where(scenario_id: data[:scenario_id]).order(:position).select { keys.include?([ it.subject_id, it.facet ]) }
    moving.each.with_index(next_position(data[:agreed_id])) do |entry, position|
      end_state = TeamPlanning::ChangeEntry.moved_end_state(entry.kind, entry.end_state, from: entry.scenario_id, to: data[:agreed_id])
      entry.update!(scenario_id: data[:agreed_id], position:, end_state:)
    end
  end

  def recorded?(event) = TeamPlanningHistoryEntry.exists?(id: event.event_id)

  # The entries go with the undos, redos and notes that name them, as one
  # block in front of the entry the plan's log puts them before; the shift goes
  # through negatives to keep positions unique.
  def rehome(event_ids, from:, to:, before: nil)
    in_from = TeamPlanningHistoryEntry.where(scenario_id: from)
    moving = in_from.where(id: event_ids).or(in_from.where(reverses_event_id: event_ids)).or(in_from.where(noted_event_id: event_ids))
                    .order(:position).to_a
    start = before && TeamPlanningHistoryEntry.find_by(id: before, scenario_id: to)&.position
    if start
      later = TeamPlanningHistoryEntry.where(scenario_id: to, position: start..)
      later.update_all([ "position = -(position + ?)", moving.size ])
      TeamPlanningHistoryEntry.where(scenario_id: to, position: ...0).update_all("position = -position")
    end
    moving.each.with_index(start || next_position(to)) do |entry, position|
      end_state = TeamPlanning::ChangeEntry.moved_end_state(entry.kind, entry.end_state, from:, to:)
      entry.update!(scenario_id: to, position:, end_state:)
    end
  end

  def record(entry)
    return if TeamPlanningHistoryEntry.exists?(id: entry.event_id)

    reversed = TeamPlanningHistoryEntry.find_by(id: entry.reverses_event_id) if entry.reverses?
    reversed&.update!(entry.action == "undo" ? { undone_by_id: entry.actor_id, undone_at: entry.at } : { undone_by_id: nil, undone_at: nil })
    TeamPlanningHistoryEntry.create!(
      id: entry.event_id, position: next_position(entry.scenario_id),
      **entry.to_h.slice(:plan_id, :scenario_id, :action, :kind, :end_state, :sealed_fields, :actor_id, :at, :note,
                         :pinned_from_scenario_id, :pinned_from_event_id, :reverses_event_id, :noted_event_id, :subject_id, :facet,
                         :settles)
    )
  end

  def next_position(scenario_id) = TeamPlanningHistoryEntry.where(scenario_id:).maximum(:position).to_i + 1
end
