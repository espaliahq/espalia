# frozen_string_literal: true

# Synchronous projection that materialises evidence items.
#
# Subscribes to the three PersonDevelopment evidence events and upserts
# {EvidenceItem} read model rows. Runs in the same transaction as the
# event publish, so a successful command leaves both the event and the
# read row durable together.
#
# Broadcasts to the same `assessment_updates` Turbo channel as
# {CurrentAssessment} so the open assessment view reloads the activity
# feed (and the evidence list inside the expanded cell) whenever
# evidence changes.
#
class PersonDevelopment::Projections::EvidenceCollection
  # Stable identifier used as the natural key in `projection_versions.name`.
  # See `docs/guidelines/event-sourcing.md` for the projection contract.
  PROJECTION_NAME = "person_development/evidence_collection"

  # Bump when `reset!` or any handler in this projection would write
  # different state from the same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      PersonDevelopment::Events::EvidenceRecorded,
      PersonDevelopment::Events::EvidenceRelinked,
      PersonDevelopment::Events::EvidenceUpdated,
      PersonDevelopment::Events::EvidenceWithdrawn
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  # Idempotent. Wrapped in tenant context so callers don't have to remember.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      EvidenceItem.where(tenant_id: tenant.id).delete_all
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
    when PersonDevelopment::Events::EvidenceRecorded then handle_recorded(event)
    when PersonDevelopment::Events::EvidenceRelinked then handle_relinked(event)
    when PersonDevelopment::Events::EvidenceUpdated then handle_updated(event)
    when PersonDevelopment::Events::EvidenceWithdrawn then handle_withdrawn(event)
    end
  end

  def handle_recorded(event)
    # Idempotent for replay: keying by the event-supplied evidence_id means
    # re-processing the same EvidenceRecorded event leaves the row in the
    # same state rather than raising RecordNotUnique.
    item = EvidenceItem.find_or_initialize_by(id: event.data[:evidence_id])
    item.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      source: event.data[:source],
      evidence_type: event.data[:evidence_type],
      custom_type_label: event.data[:custom_type_label],
      title: event.data[:title],
      content: event.data[:content],
      external_reference: external_reference_attrs(event.data[:external_reference]),
      author_id: event.data[:author_id],
      link_status: "active",
      recorded_at: event.metadata[:timestamp] || Time.current
    )
    item.save!
  end

  def handle_relinked(event)
    item = EvidenceItem.find_by(id: event.data[:evidence_id])
    return unless item

    item.update!(
      capability_stable_id: event.data[:new_capability_stable_id],
      level_ordinal: event.data[:new_level_ordinal]
    )
  end

  def handle_updated(event)
    item = EvidenceItem.find_by(id: event.data[:evidence_id])
    return unless item

    item.update!(
      title: event.data[:title],
      content: event.data[:content],
      evidence_type: event.data[:evidence_type],
      custom_type_label: event.data[:custom_type_label],
      external_reference: external_reference_attrs(event.data[:external_reference]),
      edited_at: event.metadata[:timestamp] || Time.current,
      edited_by_id: event.data[:edited_by_id]
    )
  end

  def handle_withdrawn(event)
    item = EvidenceItem.find_by(id: event.data[:evidence_id])
    return unless item

    item.update!(
      link_status: "withdrawn",
      withdrawn_at: event.metadata[:timestamp] || Time.current,
      withdrawn_by_id: event.data[:withdrawn_by_id],
      withdrawal_reason: event.data[:reason]
    )
  end

  # Coerces the event payload's external_reference (a plain Hash from the
  # JSON-serialized event) into the StoreModel's expected attribute shape.
  # Returns the column default when the payload is nil/empty.
  def external_reference_attrs(payload)
    return {} if payload.blank?

    payload.is_a?(Hash) ? payload.with_indifferent_access.slice(
      :system, :url, :external_id, :metadata
    ) : {}
  end

  # Broadcasts a sync signal to all viewers of this assessment.
  # Mirrors the {CurrentAssessment#broadcast_assessment_sync} contract so
  # the same Stimulus controller can reload both frames.
  #
  # Suppressed during replay (see `Projections::Replayer.replay_mode?`) to
  # avoid spamming live Turbo channels during a rebuild.
  def broadcast_assessment_sync(event)
    return if Projections::Replayer.replay_mode?

    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    Rails.logger.warn("[EvidenceCollection] Broadcast failed: #{e.message}")
  end

  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
