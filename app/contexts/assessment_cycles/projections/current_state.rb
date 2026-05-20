# frozen_string_literal: true

# Synchronous projection that materialises assessment cycle state.
#
# Subscribes to AssessmentCycles aggregate events and maintains the
# `assessment_cycles` and `assessment_cycle_enrollments` read models.
# Runs in the same transaction as the event publish.
#
# Owns enrollment lifecycle (enrolled / withdrawn). Per-cycle journey
# progress (started_at, alignment timestamps) lives on the sibling
# `assessment_cycle_progress` table, owned by
# {PersonDevelopment::Projections::CurrentAssessment}.
#
class AssessmentCycles::Projections::CurrentState
  # Stable identifier used as the natural key in `projection_versions.name`.
  # See `docs/guidelines/event-sourcing.md` for the projection contract.
  PROJECTION_NAME = "assessment_cycles/current_state"

  # Bump when `reset!` or any handler in this projection would write
  # different state from the same event payload than before.
  CODE_VERSION = 1

  # All event classes this projection handles.
  #
  # @return [Array<Class>]
  def self.handled_events
    [
      AssessmentCycles::Events::CycleDefined,
      AssessmentCycles::Events::PersonEnrolled,
      AssessmentCycles::Events::PersonUnenrolled,
      AssessmentCycles::Events::CycleClosed
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  # Idempotent. Wrapped in tenant context so callers don't have to remember.
  #
  # `AssessmentCycle.destroy_all` cascades via `dependent: :destroy` to
  # `enrollments` only. `assessment_cycle_progress` is owned by
  # {PersonDevelopment::Projections::CurrentAssessment} and is NOT touched
  # here — a single-projection rebuild of `assessment_cycles/current_state`
  # must not wipe another projection's read model.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      AssessmentCycle.where(tenant_id: tenant.id).destroy_all
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
    end
  end

  private

  def handle(event)
    case event
    when AssessmentCycles::Events::CycleDefined then handle_cycle_defined(event)
    when AssessmentCycles::Events::PersonEnrolled then handle_person_enrolled(event)
    when AssessmentCycles::Events::PersonUnenrolled then handle_person_unenrolled(event)
    when AssessmentCycles::Events::CycleClosed then handle_cycle_closed(event)
    end
  end

  def handle_cycle_defined(event)
    AssessmentCycle.create!(
      cycle_id: event.data[:cycle_id],
      framework_id: event.data[:framework_id],
      framework_version: event.data[:framework_version],
      name: event.data[:name],
      cycle_type: event.data[:cycle_type],
      status: "open",
      opened_at: event.metadata[:timestamp] || Time.current,
      defined_by: event.data[:defined_by]
    )
  end

  # Upserts the enrollment row rather than unconditionally creating one.
  #
  # The `assessment_cycle_enrollments` table has a unique index on
  # `(cycle_id, person_id)`, and `handle_person_unenrolled` preserves
  # withdrawn rows by flipping `status` rather than deleting. Without the
  # upsert below, re-enrolling a previously-withdrawn participant collides
  # with the stale row via `idx_assessment_cycle_enrollments_unique`.
  def handle_person_enrolled(event)
    enrollment = AssessmentCycleEnrollment.find_or_initialize_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.data[:person_id]
    )
    enrollment.assign_attributes(
      status: "enrolled",
      enrolled_at: event.metadata[:timestamp] || Time.current,
      withdrawn_at: nil,
      withdrawal_reason: nil
    )
    enrollment.save!
  end

  def handle_person_unenrolled(event)
    enrollment = AssessmentCycleEnrollment.find_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.data[:person_id]
    )
    return unless enrollment

    enrollment.update!(
      status: "withdrawn",
      withdrawn_at: event.metadata[:timestamp] || Time.current,
      withdrawal_reason: event.data[:reason]
    )
  end

  def handle_cycle_closed(event)
    cycle = AssessmentCycle.find_by(cycle_id: event.data[:cycle_id])
    return unless cycle

    closed_at = event.metadata[:timestamp] || Time.current
    cycle.update!(status: "closed", closed_at: closed_at)

    # Mark any still-enrolled participants as withdrawn with cycle_closed reason
    cycle.enrollments.where.not(status: "withdrawn").find_each do |enrollment|
      enrollment.update!(
        status: "withdrawn",
        withdrawn_at: closed_at,
        withdrawal_reason: "cycle_closed"
      )
    end
  end

  # Sets tenant context from event metadata for projection writes.
  #
  # @param event [RubyEventStore::Event]
  # @yield block to execute within tenant context
  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
