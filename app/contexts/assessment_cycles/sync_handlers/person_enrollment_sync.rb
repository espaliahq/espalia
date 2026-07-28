# frozen_string_literal: true

# Cross-stream synchronous handler: propagates AssessmentCycle enrollment
# events to PersonDevelopment streams.
#
# When a person is enrolled into (or unenrolled from) a cycle, or the cycle
# closes around them, this handler dispatches a PersonDevelopment command
# which emits a corresponding `JoinedAssessmentCycle` / `LeftAssessmentCycle`
# / `AssessmentCycleConcluded` event on the person's PersonDev stream. This
# keeps the PersonDev stream self-contained — replaying it tells the full
# story of when the person was in which cycle and how each stint ended.
#
# IMPORTANT INVARIANTS
# ====================
#
# 1. **Same transaction as originator**: registered via `event_store.subscribe`
#    so the PersonDev command dispatch runs inline with the cycle-event publish.
#    Handler failure rolls back the originating cycle command — an enrollment
#    that can't propagate to the person stream must be rejected cleanly.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches commands,
#    not just read-model writes. Running it twice would raise "already in a cycle"
#    from the PersonDev aggregate. Register strictly as a subscription, NOT as a
#    projection. Do not add it to any rebuild list or replay pathway.
#
# 3. **Stateless**: cycle events are self-describing (carry framework_id +
#    framework_version). The handler never reads a cycle read model.
#
class AssessmentCycles::SyncHandlers::PersonEnrollmentSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [
      AssessmentCycles::Events::PersonEnrolled,
      AssessmentCycles::Events::PersonUnenrolled,
      AssessmentCycles::Events::CycleClosed
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
    case event
    when AssessmentCycles::Events::PersonEnrolled then handle_person_enrolled(event)
    when AssessmentCycles::Events::PersonUnenrolled then handle_person_unenrolled(event)
    when AssessmentCycles::Events::CycleClosed then handle_cycle_closed(event)
    end
  end

  def handle_person_enrolled(event)
    person_id = event.data[:person_id]
    framework_id = event.data[:framework_id]
    cycle_id = event.data[:cycle_id]

    command_handler.join_cycle(person_id, framework_id, cycle_id, event.data[:framework_version])
    seed_from_prior_cycle(person_id, framework_id, cycle_id, event.data[:enrolled_by])
  end

  # Seeds the new cycle's ratings from the person's MOST RECENT prior
  # participation in this framework — aligned or not (per-cell precedence
  # happens in the command handler). Most-recent-participation is lossless
  # by construction: seeding chains, so an unaligned Q2 already contains
  # Q1's aligned baseline plus whatever moved since — skipping back to the
  # last *aligned* cycle would discard newer information. Withdrawn and
  # concluded enrollments both count: however the stint ended, its ratings
  # are the person's latest known state. No-op when this is their first
  # cycle.
  def seed_from_prior_cycle(person_id, framework_id, current_cycle_id, enrolled_by)
    # Use the association join (not a raw SQL join) so ActsAsTenant adds
    # the assessment_cycles tenant filter — otherwise the lookup could
    # resolve against another tenant's cycle row.
    prior_cycle_id = AssessmentCycleEnrollment
      .where(person_id: person_id)
      .where.not(cycle_id: current_cycle_id)
      .joins(:cycle)
      .where(assessment_cycles: { framework_id: framework_id })
      .order("assessment_cycles.opened_at DESC")
      .limit(1)
      .pluck(:cycle_id)
      .first

    return unless prior_cycle_id

    command_handler.seed_ratings_from_prior_cycle(
      person_id, framework_id, current_cycle_id, prior_cycle_id,
      seeded_by_id: enrolled_by
    )
  end

  def handle_person_unenrolled(event)
    command_handler.leave_cycle(
      event.data[:person_id],
      event.data[:framework_id],
      event.data[:cycle_id],
      event.data[:reason]
    )
  end

  # Cycle closure is a conclusion, not a removal: every still-enrolled
  # participant's PersonDev stream records AssessmentCycleConcluded (their
  # participation stands as part of the cycle's cohort), never a
  # LeftAssessmentCycle — that event is reserved for person-scoped
  # unenrollment.
  def handle_cycle_closed(event)
    Array(event.data[:enrolled_person_ids]).each do |person_id|
      command_handler.conclude_cycle(
        person_id,
        event.data[:framework_id],
        event.data[:cycle_id]
      )
    end
  end

  def command_handler
    @command_handler ||= PersonDevelopment::CommandHandler.new
  end
end
