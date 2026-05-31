# frozen_string_literal: true

# Cross-stream synchronous handler: keeps an open cycle's per-participant
# assessed role/level in step with the person's actual role/level when it
# changes mid-cycle (a promotion or transfer).
#
# Fires on PersonDevelopment::Events::PersonLevelChanged /
# PersonRoleChanged, finds the person's open cycle for that framework, and
# issues `update_participant_role` to the AssessmentCycle aggregate — which
# owns "assessed role/level" as a first-class fact and guards that the cycle
# is open + the person enrolled (and no-ops when unchanged).
#
# IMPORTANT INVARIANTS (mirror AutoEnrollNewAssignments)
# ======================================================
#
# 1. **Same transaction as originator**: registered via `event_store.subscribe`
#    so the dispatch runs inline with the level/role-change publish.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches commands.
#    Replaying it would re-issue cycle commands against already-current state.
#    Register strictly as a subscription, NOT as a projection — and it stays
#    out of `Projections::Registry::REPLAYABLE` (asserted by the registry test).
#
# 3. **Silent no-op when no open enrolled cycle exists** for the framework —
#    a change outside any cycle, or for a closed cycle, simply does nothing
#    (closed cycles stay frozen at their last assessed level).
#
class AssessmentCycles::SyncHandlers::ParticipantRoleSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [
      PersonDevelopment::Events::PersonLevelChanged,
      PersonDevelopment::Events::PersonRoleChanged
    ]
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant) do
      handle(event)
    end
  end

  private

  def handle(event)
    framework_id = event.metadata[:framework_id]
    person_id = event.metadata[:person_id]
    role_id, level_id = resolve_role_level(event, person_id, framework_id)
    return unless role_id && level_id

    cycle = AssessmentCycle.open_cycles.for_framework(framework_id).first
    return unless cycle
    return unless AssessmentCycleEnrollment
                  .where(cycle_id: cycle.cycle_id, person_id: person_id)
                  .active.exists?

    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.update_participant_role(
        cycle.cycle_id, person_id, role_id, level_id,
        reason: event.data[:reason] || "hris_sync"
      )
    end
  end

  # Resolves the new (role_id, level_id) the participant should be assessed
  # against. A role change carries both new ids; a level change carries only
  # the new level, so the role is read from the (role-unchanged) assignment.
  #
  # @return [Array(String, String)] [role_id, level_id], either may be nil
  def resolve_role_level(event, person_id, framework_id)
    case event
    when PersonDevelopment::Events::PersonRoleChanged
      [ event.data[:new_role_id], event.data[:new_level_id] ]
    when PersonDevelopment::Events::PersonLevelChanged
      assignment = PersonFrameworkAssignment.find_by(person_id: person_id, framework_id: framework_id)
      [ assignment&.role_id, event.data[:new_level_id] ]
    end
  end
end
