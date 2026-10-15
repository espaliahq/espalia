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
  #
  # 2 — handles `FrameworkVersionMigrated`: re-keys evidence rows onto
  #     the survivor `to_stable_id` for same/evolved mappings, and
  #     withdraws orphans for archived/split.
  # 3 — multi-linkage evidence. Writes the new `evidence_links` table
  #     (one active link per cell an item appears in), so `reset!` now
  #     truncates it too, and `EvidenceRecorded` / `EvidenceLinkAdded` /
  #     `EvidenceLinkRemoved` / historical `EvidenceRelinked` /
  #     `FrameworkVersionMigrated` maintain link rows. The
  #     `evidence_items` content row (incl. its origin coordinate columns)
  #     is unchanged from v2.
  CODE_VERSION = 3

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      PersonDevelopment::Events::EvidenceRecorded,
      PersonDevelopment::Events::EvidenceLinkAdded,
      PersonDevelopment::Events::EvidenceLinkRemoved,
      PersonDevelopment::Events::EvidenceLinkRevalenced,
      PersonDevelopment::Events::EvidenceRelinked,
      PersonDevelopment::Events::EvidenceUpdated,
      PersonDevelopment::Events::EvidenceWithdrawn,
      PersonDevelopment::Events::FrameworkVersionMigrated
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  # Idempotent. Wrapped in tenant context so callers don't have to remember.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      EvidenceLink.where(tenant_id: tenant.id).delete_all
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
    when PersonDevelopment::Events::EvidenceLinkAdded then handle_link_added(event)
    when PersonDevelopment::Events::EvidenceLinkRemoved then handle_link_removed(event)
    when PersonDevelopment::Events::EvidenceLinkRevalenced then handle_link_revalenced(event)
    when PersonDevelopment::Events::EvidenceRelinked then handle_relinked(event)
    when PersonDevelopment::Events::EvidenceUpdated then handle_updated(event)
    when PersonDevelopment::Events::EvidenceWithdrawn then handle_withdrawn(event)
    when PersonDevelopment::Events::FrameworkVersionMigrated then handle_framework_version_migrated(event)
    end
  end

  # Applies the migration mappings to this person's evidence rows AND their
  # links. `evolved` re-keys both the item's origin column and the matching
  # link rows onto the survivor (merging where the item is already linked
  # there — see `rekey_links`); `same` carries no survivor and is a no-op, as
  # is a self-mapping; `archived`/`split` remove the matching link rows (the
  # underlying capability is gone, so the evidence has nowhere to live
  # there). An item is withdrawn only when it has NO remaining active links
  # after the pass — multi-link items that still have a home survive. `new`
  # is a no-op (no predecessor evidence).
  def handle_framework_version_migrated(event)
    person_id = event.metadata[:person_id]
    framework_id = event.data[:framework_id]
    timestamp = event.metadata[:timestamp] || Time.current
    touched_evidence_ids = []

    event.data[:mappings].each do |mapping|
      link_scope = EvidenceLink.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: mapping[:from_stable_id]
      )
      item_scope = EvidenceItem.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: mapping[:from_stable_id]
      )
      case mapping[:mapping_type]
      when "same", "evolved"
        to_stable_id = mapping[:to_stable_id]
        next if to_stable_id.nil? || to_stable_id == mapping[:from_stable_id]

        # Only mappings that actually touch links feed the withdrawal pass,
        # so a no-op mapping never sweeps up an unrelated link-less item.
        touched_evidence_ids.concat(link_scope.pluck(:evidence_id))
        rekey_links(link_scope, to_stable_id, timestamp)
        item_scope.update_all(capability_stable_id: to_stable_id)
      when "archived", "split"
        touched_evidence_ids.concat(link_scope.pluck(:evidence_id))
        link_scope.where(link_status: "active").update_all(
          link_status: "removed",
          removed_at: timestamp,
          removal_reason: "framework_migration_#{mapping[:mapping_type]}"
        )
      when "new"
        # No predecessor evidence to touch.
      end
    end

    withdraw_items_without_active_links(touched_evidence_ids.uniq, timestamp)
  end

  # Moves every link in `scope` (links anchored on the retiring capability)
  # onto `to_stable_id`, except where the same evidence item already has a
  # link to the survivor at that level — `idx_evidence_links_natural_key` is
  # unique on (evidence_id, capability_stable_id, level_ordinal) regardless of
  # `link_status`, so those cannot be re-keyed.
  #
  # Non-colliding links are re-keyed in one UPDATE (NOT EXISTS); whatever is
  # still active under the retiring id is by construction the colliding set.
  # For each: if the survivor link is itself removed, it is revived with the
  # retiring link's provenance (the retiring link was the item's live anchor,
  # and `upsert_link` revives the same way), then the retiring link is closed
  # as `framework_migration_merged`, mirroring the archived/split branch. The
  # item always keeps exactly one active link at the survivor, so
  # `withdraw_items_without_active_links` leaves it alone.
  #
  # @param scope [ActiveRecord::Relation<EvidenceLink>] links under the
  #   retiring capability for this person/framework
  # @param to_stable_id [String] survivor capability stable id
  # @param timestamp [Time] migration time, stamped on merged links
  def rekey_links(scope, to_stable_id, timestamp)
    scope.where.not(<<~SQL.squish, to_stable_id).update_all(capability_stable_id: to_stable_id)
      EXISTS (
        SELECT 1 FROM evidence_links survivor
        WHERE survivor.evidence_id = evidence_links.evidence_id
          AND survivor.level_ordinal = evidence_links.level_ordinal
          AND survivor.capability_stable_id = ?
      )
    SQL

    scope.active.find_each do |retiring|
      survivor = EvidenceLink.find_by!(
        evidence_id: retiring.evidence_id, level_ordinal: retiring.level_ordinal,
        capability_stable_id: to_stable_id
      )
      unless survivor.link_status == "active"
        survivor.update!(
          link_status: "active",
          linked_by_id: retiring.linked_by_id, linked_at: retiring.linked_at, valence: retiring.valence,
          removed_at: nil, removed_by_id: nil, removal_reason: nil
        )
      end
      retiring.update!(link_status: "removed", removed_at: timestamp,
                       removal_reason: "framework_migration_merged")
    end
  end

  # After a migration pass that may have removed link rows, withdraw any
  # touched item that has been left with zero active links.
  def withdraw_items_without_active_links(evidence_ids, timestamp)
    return if evidence_ids.empty?

    EvidenceItem.where(id: evidence_ids, link_status: "active").find_each do |item|
      next if item.evidence_links.active.exists?

      item.update!(
        link_status: "withdrawn",
        withdrawn_at: timestamp,
        withdrawal_reason: "framework_migration_orphaned"
      )
    end
  end

  def handle_recorded(event)
    # Idempotent for replay: keying by the event-supplied evidence_id means
    # re-processing the same EvidenceRecorded event leaves the row in the
    # same state rather than raising RecordNotUnique.
    #
    # cycle_id and feedback_direction were introduced with the event payloads
    # that can populate them. Historical events lack the keys and therefore
    # replay to the columns' existing nil values, so these additive
    # attributions need no version bump.
    item = EvidenceItem.find_or_initialize_by(id: event.data[:evidence_id])
    item.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      cycle_id: event.data[:cycle_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      source: event.data[:source],
      feedback_direction: event.data[:feedback_direction],
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

    # An unplaced item carries no capability on the event and starts with
    # no link row; its first EvidenceLinkAdded places it.
    return if event.data[:capability_stable_id].nil?

    upsert_link(event, event.data[:capability_stable_id], event.data[:level_ordinal],
                linked_by_id: event.data[:author_id], valence: event.data[:valence])
  end

  def handle_link_added(event)
    upsert_link(event, event.data[:capability_stable_id], event.data[:level_ordinal],
                linked_by_id: event.data[:linked_by_id], valence: event.data[:valence])
    adopt_origin_from_first_placement(event)
  end

  # An item recorded unplaced has no origin; its first placement becomes it,
  # so every reader anchored on the origin columns (the feed, the hub, the
  # reporting joins) sees the cell the item now lives in. Deterministic on
  # replay: the first EvidenceLinkAdded after an origin-less EvidenceRecorded
  # always wins.
  def adopt_origin_from_first_placement(event)
    EvidenceItem.where(id: event.data[:evidence_id], capability_stable_id: nil)
      .update_all(capability_stable_id: event.data[:capability_stable_id], level_ordinal: event.data[:level_ordinal])
  end

  def handle_link_revalenced(event)
    link = EvidenceLink.find_by(
      evidence_id: event.data[:evidence_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal]
    )
    return unless link

    link.update!(valence: event.data[:valence])
  end

  def handle_link_removed(event)
    link = EvidenceLink.find_by(
      evidence_id: event.data[:evidence_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal]
    )
    return unless link

    link.update!(
      link_status: "removed",
      removed_at: event.metadata[:timestamp] || Time.current,
      removed_by_id: event.data[:removed_by_id],
      removal_reason: event.data[:reason]
    )
  end

  # Historical event — no longer emitted. Replays as remove-previous-link
  # + add-new-link on the link table, and moves the item's origin columns
  # (preserving the pre-multi-link activity-feed anchor behaviour).
  def handle_relinked(event)
    item = EvidenceItem.find_by(id: event.data[:evidence_id])
    return unless item

    previous = EvidenceLink.find_by(
      evidence_id: event.data[:evidence_id],
      capability_stable_id: event.data[:previous_capability_stable_id],
      level_ordinal: event.data[:previous_level_ordinal]
    )
    previous&.update!(
      link_status: "removed",
      removed_at: event.metadata[:timestamp] || Time.current,
      removal_reason: "relinked"
    )

    upsert_link(event, event.data[:new_capability_stable_id], event.data[:new_level_ordinal],
                linked_by_id: event.data[:relinked_by_id], valence: nil)

    item.update!(
      capability_stable_id: event.data[:new_capability_stable_id],
      level_ordinal: event.data[:new_level_ordinal]
    )
  end

  # Upserts an active link row keyed by the natural key
  # (evidence_id, capability_stable_id, level_ordinal). Idempotent for
  # replay; re-activates a previously-removed link if the same coordinate
  # is added again. `valence` is nil for events published before valence
  # existed (`event.data[:valence]` on those returns nil) — the column
  # stays at its default, so no CODE_VERSION bump / rebuild is needed.
  def upsert_link(event, capability_stable_id, level_ordinal, linked_by_id:, valence:)
    link = EvidenceLink.find_or_initialize_by(
      evidence_id: event.data[:evidence_id],
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal
    )
    link.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      link_status: "active",
      linked_by_id: linked_by_id,
      linked_at: event.metadata[:timestamp] || Time.current,
      valence: valence,
      removed_at: nil,
      removed_by_id: nil,
      removal_reason: nil
    )
    link.save!
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
