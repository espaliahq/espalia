# frozen_string_literal: true

# Synchronous projection of what each scenario of a live plan overrides: one
# row per subject and facet, from the last change the scenario set there or
# the pin it made.
#
# Writes `team_planning_overrides`, and nothing else writes it. A clear
# removes the row, as does a removed scenario or a deleted plan; the stream
# keeps them all. An undo or redo puts back the change or pin its event names
# as then in effect for its subject and facet, with the note it last had, or
# removes the row. A note rewrites the note of the row its change made. A split
# moves the rows of its subjects and facets to the agreed part. It reads
# each event through {TeamPlanning::ChangeEntry} and hears every kind
# in {TeamPlanning::ChangeKinds}.
#
class TeamPlanning::Projections::Overrides
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "team_planning/overrides"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    TeamPlanning::ChangeKinds.all + [ TeamPlanning::Events::ChangeCleared, TeamPlanning::Events::ChangePinned,
                                      TeamPlanning::Events::ChangeUndone, TeamPlanning::Events::ChangeRedone,
                                      TeamPlanning::Events::ChangeNoted, TeamPlanning::Events::ScenarioSplit,
                                      TeamPlanning::Events::ScenarioRemoved, TeamPlanning::Events::PlanDeleted ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { TeamPlanningOverride.where(tenant_id: tenant.id).delete_all }
  end

  # @param event_store [RubyEventStore::Client] where an undo or redo reads the change it puts back
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      case event
      when TeamPlanning::Events::ScenarioRemoved then TeamPlanningOverride.where(scenario_id: event.data[:scenario_id]).delete_all
      when TeamPlanning::Events::PlanDeleted then TeamPlanningOverride.where(plan_id: event.data[:plan_id]).delete_all
      when TeamPlanning::Events::ScenarioSplit then split(event.data)
      else apply(TeamPlanning::ChangeEntry.from(event), event)
      end
    end
  end

  private

  def split(data)
    data[:keys].each do |subject_id, facet|
      TeamPlanningOverride.where(scenario_id: data[:scenario_id], subject_id:, facet:).update_all(scenario_id: data[:agreed_id])
    end
  end

  def apply(entry, event)
    if entry.reverses? then restore(entry, event)
    elsif entry.notes? then TeamPlanningOverride.find_by(scenario_id: entry.scenario_id, event_id: entry.noted_event_id)&.update!(note: entry.note)
    elsif entry.sets? then write(entry)
    else TeamPlanningOverride.where(entry.to_h.slice(:scenario_id, :subject_id, :facet)).delete_all
    end
  end

  def write(entry, note: entry.note)
    row = TeamPlanningOverride.find_or_initialize_by(**entry.to_h.slice(:scenario_id, :subject_id, :facet))
    row.update!(**entry.to_h.slice(:plan_id, :kind, :end_state, :pinned_from_scenario_id, :pinned_from_event_id),
                pinned: entry.action == "pin", set_by_id: entry.actor_id, event_id: entry.event_id, set_at: entry.at, note:)
  end

  def restore(entry, event)
    in_effect_event_id = event.data[:in_effect_event_id] or
      return TeamPlanningOverride.where(entry.to_h.slice(:scenario_id, :subject_id, :facet)).delete_all

    restored = TeamPlanning::ChangeEntry.from(@event_store.read.event(in_effect_event_id))
    write(restored, note: note_before(event, restored))
  end

  # The note the restored change had when the undo or redo came: its last
  # rewrite before then, or the note it was made with.
  def note_before(event, restored)
    stream = EventStreamNaming.plan_stream(restored.plan_id)
    noted = @event_store.read.stream(stream).backward.from(event.event_id).of_type(TeamPlanning::Events::ChangeNoted)
                        .each.find { it.data[:noted_event_id] == restored.event_id }
    noted ? noted.data[:note] : restored.note
  end
end
