# frozen_string_literal: true

# Synchronous projection that materialises calibration session state.
#
# Subscribes to CalibrationSession aggregate events and maintains the
# `calibration_sessions` and `calibration_session_members` read models.
# Runs in the same transaction as the event publish.
#
# The session row's primary key IS the event-carried session_id, so
# externally-held references (URLs, MCP) survive rebuilds. Membership
# rows are deleted on removal — curation history lives on the stream.
#
class AssessmentCycles::Projections::CalibrationSessions
  # Stable identifier used as the natural key in `projection_versions.name`.
  # See `docs/guidelines/event-sourcing.md` for the projection contract.
  PROJECTION_NAME = "assessment_cycles/calibration_sessions"

  # Bump when `reset!` or any handler in this projection would write
  # different state from the same event payload than before.
  CODE_VERSION = 1

  # All event classes this projection handles.
  #
  # @return [Array<Class>]
  def self.handled_events
    [
      AssessmentCycles::Events::CalibrationSessionDefined,
      AssessmentCycles::Events::CalibrationParticipantAdded,
      AssessmentCycles::Events::CalibrationParticipantRemoved,
      AssessmentCycles::Events::CalibrationCalibrantAdded,
      AssessmentCycles::Events::CalibrationCalibrantRemoved,
      AssessmentCycles::Events::CalibrationSessionStarted,
      AssessmentCycles::Events::CalibrationSessionClosed
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  # Idempotent. `destroy_all` cascades to members via `dependent: :destroy`.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      CalibrationSession.where(tenant_id: tenant.id).destroy_all
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
    when AssessmentCycles::Events::CalibrationSessionDefined then handle_defined(event)
    when AssessmentCycles::Events::CalibrationParticipantAdded then handle_member_added(event, "participant", event.data[:participant_id])
    when AssessmentCycles::Events::CalibrationParticipantRemoved then handle_member_removed(event, event.data[:participant_id])
    when AssessmentCycles::Events::CalibrationCalibrantAdded then handle_member_added(event, "calibrant", event.data[:person_id])
    when AssessmentCycles::Events::CalibrationCalibrantRemoved then handle_member_removed(event, event.data[:person_id])
    when AssessmentCycles::Events::CalibrationSessionStarted then handle_started(event)
    when AssessmentCycles::Events::CalibrationSessionClosed then handle_closed(event)
    end
  end

  # Upserts the session row (idempotent replay) and rebuilds its seeded
  # membership from the event's participant/calibrant arrays.
  def handle_defined(event)
    session = CalibrationSession.find_or_initialize_by(id: event.data[:session_id])
    session.assign_attributes(
      cycle_id: event.data[:cycle_id],
      framework_id: event.data[:framework_id],
      framework_version: event.data[:framework_version],
      name: event.data[:name],
      facilitator_id: event.data[:facilitator_id],
      status: "draft",
      defined_by: event.data[:defined_by]
    )
    session.save!

    session.members.delete_all
    (event.data[:participant_ids] || []).each do |person_id|
      create_member(session, person_id, "participant", event.data[:defined_by])
    end
    (event.data[:calibrant_person_ids] || []).each do |person_id|
      create_member(session, person_id, "calibrant", event.data[:defined_by])
    end
  end

  # Idempotent add: the unique (session_id, person_id) index backs the
  # upsert so a replayed event never duplicates a row. member_type is
  # overwritten deliberately — the aggregate's became_participant removal
  # always precedes a role change, so convergence is safe either way.
  def handle_member_added(event, member_type, person_id)
    session = find_session(event)
    return unless session

    member = CalibrationSessionMember.find_or_initialize_by(
      session_id: session.id,
      person_id: person_id
    )
    member.assign_attributes(member_type: member_type, added_by: event.data[:added_by])
    member.save!
  end

  def handle_member_removed(event, person_id)
    session = find_session(event)
    return unless session

    session.members.where(person_id: person_id).delete_all
  end

  def handle_started(event)
    session = find_session(event)
    return unless session

    session.update!(
      status: "started",
      started_by_id: event.data[:started_by_id],
      started_at: event.metadata[:timestamp] || Time.current
    )
  end

  def handle_closed(event)
    session = find_session(event)
    return unless session

    session.update!(
      status: "closed",
      closed_by_id: event.data[:closed_by_id],
      close_reason: event.data[:reason],
      closed_at: event.metadata[:timestamp] || Time.current
    )
  end

  def create_member(session, person_id, member_type, added_by)
    CalibrationSessionMember.create!(
      session_id: session.id,
      person_id: person_id,
      member_type: member_type,
      added_by: added_by
    )
  end

  def find_session(event)
    CalibrationSession.find_by(id: event.data[:session_id])
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
