# frozen_string_literal: true

# Cross-stream synchronous handler: auto-enrolls a person into the
# currently-open assessment cycle for their framework when they are first
# assigned.
#
# Fires on PersonDevelopment::Events::PersonAssignedToFramework — which
# includes both HRIS-driven new hires and manually-created assignments.
#
# IMPORTANT INVARIANTS (mirror PersonEnrollmentSync)
# ===================================================
#
# 1. **Same transaction as originator**: registered via `event_store.subscribe`
#    so the enrollment dispatch runs inline with the assignment event publish.
#    If the enrollment fails, the originating assignment also rolls back.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches commands.
#    Running it twice would raise "Person already enrolled" on the cycle
#    aggregate. Register strictly as a subscription, NOT as a projection.
#
# 3. **Silent no-op when no open cycle exists** for the framework — not every
#    assignment needs to trigger enrollment; the admin may not have opened a
#    cycle yet.
#
# 4. **Idempotent at the read-model level**: skipped if a live (non-withdrawn)
#    participant row already exists. This handles the case where a manual
#    enrollment happened first and the HRIS sync then fires the assign event.
#
class AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [ PersonDevelopment::Events::PersonAssignedToFramework ]
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
    framework_id = event.data[:framework_id]
    person_id = event.data[:person_id]

    cycle = AssessmentCycle.open_cycles.for_framework(framework_id).first
    return unless cycle

    return if AssessmentCycleEnrollment
              .where(cycle_id: cycle.cycle_id, person_id: person_id)
              .active.exists?

    # Wrap the dispatch in a transaction so the downstream
    # PersonEnrollmentSync -> join_cycle chain either commits fully or
    # rolls back the AssessmentCycleEnrollment projection write. RES
    # subscribers run synchronously but NOT in an implicit DB transaction.
    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.enroll(
        cycle.cycle_id, person_id, enrolled_by: nil
      )
    end
  end
end
