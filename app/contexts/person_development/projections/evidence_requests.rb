# frozen_string_literal: true

# Synchronous projection that materialises {EvidenceRequest} rows from the
# PersonDevelopment stream. Sole writer of the `evidence_requests` table.
#
# Runs in the same transaction as the event publish and broadcasts the same
# `assessment_updates` sync signal as the other PD projections, so an open
# assessment / evidence view reloads when a request changes.
class PersonDevelopment::Projections::EvidenceRequests
  # Stable identifier; natural key in `projection_versions.name`.
  PROJECTION_NAME = "person_development/evidence_requests"

  # Bump when reset!/handler logic would produce different state for past events.
  CODE_VERSION = 1

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      PersonDevelopment::Events::EvidenceRequested,
      PersonDevelopment::Events::EvidenceRequestResponded,
      PersonDevelopment::Events::EvidenceRequestDeclined,
      PersonDevelopment::Events::EvidenceRequestCancelled,
      PersonDevelopment::Events::EvidenceRequestReminderSent
    ]
  end

  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { EvidenceRequest.where(tenant_id: tenant.id).delete_all }
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
    when PersonDevelopment::Events::EvidenceRequested then handle_requested(event)
    when PersonDevelopment::Events::EvidenceRequestResponded then handle_responded(event)
    when PersonDevelopment::Events::EvidenceRequestDeclined then handle_declined(event)
    when PersonDevelopment::Events::EvidenceRequestCancelled then handle_cancelled(event)
    when PersonDevelopment::Events::EvidenceRequestReminderSent then handle_reminder_sent(event)
    end
  end

  def handle_requested(event)
    request = EvidenceRequest.find_or_initialize_by(id: event.data[:request_id])
    request.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      requested_by_id: event.data[:requested_by_id],
      requestee_person_id: event.data[:requestee_person_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      message: event.data[:message],
      due_at: event.data[:due_at],
      status: "pending",
      requested_at: event.metadata[:timestamp]
    )
    request.save!
  end

  def handle_responded(event)
    EvidenceRequest.where(id: event.data[:request_id]).update_all(
      status: "responded",
      evidence_id: event.data[:evidence_id],
      responded_at: event.metadata[:timestamp],
      updated_at: Time.current
    )
  end

  def handle_declined(event)
    EvidenceRequest.where(id: event.data[:request_id]).update_all(
      status: "declined",
      decline_reason: event.data[:reason],
      declined_at: event.metadata[:timestamp],
      updated_at: Time.current
    )
  end

  def handle_cancelled(event)
    EvidenceRequest.where(id: event.data[:request_id]).update_all(
      status: "cancelled",
      cancelled_at: event.metadata[:timestamp],
      updated_at: Time.current
    )
  end

  def handle_reminder_sent(event)
    column = event.data[:kind] == "due_soon" ? :due_soon_reminded_at : :no_response_reminded_at
    EvidenceRequest.where(id: event.data[:request_id]).update_all(
      column => event.metadata[:timestamp],
      updated_at: Time.current
    )
  end

  def broadcast_assessment_sync(event)
    return if Projections::Replayer.replay_mode?

    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    Rails.logger.warn("[EvidenceRequests] Broadcast failed: #{e.message}")
  end

  def with_tenant(event, &)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id]), &)
  end
end
