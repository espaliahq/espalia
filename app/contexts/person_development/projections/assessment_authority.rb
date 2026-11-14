# frozen_string_literal: true

# Synchronous projection that materialises assessment *authority* facts from
# the PersonDevelopment stream into two read models it owns exclusively:
#
# * `RecordedReportingManager` — the reporting manager per (person, framework),
#   the authoritative source for "who may manager-rate".
# * `ManagerAssessmentDelegation` — grants of manager-rating authority to
#   another person.
#
# Kept separate from {PersonDevelopment::Projections::CurrentAssessment} so
# adding it does not bump that projection's CODE_VERSION, and so each table has
# a single writer (see docs/guidelines/event-sourcing.md).
#
class PersonDevelopment::Projections::AssessmentAuthority
  PROJECTION_NAME = "person_development/assessment_authority"
  # 2 — `ManagerAssessmentDelegation` now derives its primary key
  #     deterministically from `(person_id, framework_id, delegate_person_id)`
  #     via {DeterministicId}, instead of a random `uuid_v7` minted at
  #     projection time. A rebuild re-keys every delegation row to its
  #     deterministic id (one-time PK churn; thereafter stable). Requires a
  #     rebuild (REBUILD_ON_DEPLOY=person_development/assessment_authority).
  #     `RecordedReportingManager` is unaffected (not externally addressed by
  #     PK), but shares this projection's rebuild.
  CODE_VERSION = 2

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      PersonDevelopment::Events::ReportingManagerRecorded,
      PersonDevelopment::Events::ManagerRatingDelegated,
      PersonDevelopment::Events::ManagerRatingDelegationRevoked
    ]
  end

  # Truncates both owned read models, scoped to one tenant. Idempotent.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      RecordedReportingManager.where(tenant_id: tenant.id).delete_all
      ManagerAssessmentDelegation.where(tenant_id: tenant.id).delete_all
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
      broadcast_assessment_sync(event)
    end
  end

  private

  def handle(event)
    case event
    when PersonDevelopment::Events::ReportingManagerRecorded then handle_reporting_manager_recorded(event)
    when PersonDevelopment::Events::ManagerRatingDelegated then handle_delegated(event)
    when PersonDevelopment::Events::ManagerRatingDelegationRevoked then handle_revoked(event)
    end
  end

  def handle_reporting_manager_recorded(event)
    scope = { tenant_id: event.metadata[:tenant_id], person_id: event.metadata[:person_id],
              framework_id: event.metadata[:framework_id] }
    return RecordedReportingManager.where(scope).delete_all if event.data[:manager_id].nil?

    record = RecordedReportingManager.find_or_initialize_by(scope)
    record.manager_id = event.data[:manager_id]
    record.source = event.data[:source]
    record.save!
  end

  def handle_delegated(event)
    delegation = ManagerAssessmentDelegation.find_or_initialize_by(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      delegate_person_id: event.data[:delegate_person_id]
    )
    delegation.assign_attributes(
      granted_by_id: event.data[:granted_by_id],
      expires_at: event.data[:expires_at],
      reason: event.data[:reason],
      status: "active",
      revoked_at: nil,
      revoked_by_id: nil
    )
    delegation.save!
  end

  def handle_revoked(event)
    delegation = ManagerAssessmentDelegation.find_by(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      delegate_person_id: event.data[:delegate_person_id]
    )
    return unless delegation

    delegation.update!(
      status: "revoked",
      revoked_at: event.metadata[:timestamp] || Time.current,
      revoked_by_id: event.data[:revoked_by_id]
    )
  end

  # Nudges the assessment-sync signal so any open assessment view reloads
  # its activity feed (delegation grant/revoke and reporting-manager changes
  # are on-screen actions that must surface there in real time — see the
  # activity-feed coverage rule in docs/guidelines/assessments.md).
  # Suppressed during replay to avoid spamming live channels on a rebuild.
  def broadcast_assessment_sync(event)
    return if Projections::Replayer.replay_mode?

    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    Rails.logger.warn("[AssessmentAuthority] Broadcast failed: #{e.message}")
  end

  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
