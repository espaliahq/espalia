# frozen_string_literal: true

# Synchronous projection of what each scenario of a live plan overrides: one
# row per subject and facet, from the last change the scenario set there or
# the pin it made.
#
# Writes `team_planning_overrides`, and nothing else writes it. A clear
# removes the row, as does a removed scenario or a deleted plan; the stream
# keeps them all. It hears every kind in {TeamPlanning::ChangeKinds}.
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
                                      TeamPlanning::Events::ScenarioRemoved, TeamPlanning::Events::PlanDeleted ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { TeamPlanningOverride.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      data = event.data
      case event
      when TeamPlanning::Events::Change
        write(event, facet: event.key.last, kind: event.class.name, end_state: data.except(*TeamPlanning::Events::Change::FIELDS),
                     pinned: false, pinned_from_scenario_id: nil, pinned_from_event_id: nil, set_by_id: data[:set_by_id])
      when TeamPlanning::Events::ChangePinned
        write(event, **data.slice(:facet, :kind, :end_state, :pinned_from_scenario_id, :pinned_from_event_id),
                     pinned: true, set_by_id: data[:pinned_by_id])
      when TeamPlanning::Events::ChangeCleared
        TeamPlanningOverride.where(data.slice(:scenario_id, :subject_id, :facet)).delete_all
      when TeamPlanning::Events::ScenarioRemoved then TeamPlanningOverride.where(scenario_id: data[:scenario_id]).delete_all
      when TeamPlanning::Events::PlanDeleted then TeamPlanningOverride.where(plan_id: data[:plan_id]).delete_all
      end
    end
  end

  private

  def write(event, facet:, **attributes)
    row = TeamPlanningOverride.find_or_initialize_by(**event.data.slice(:scenario_id, :subject_id), facet:)
    row.update!(**attributes, plan_id: event.data[:plan_id], event_id: event.event_id, set_at: event.timestamp)
  end
end
