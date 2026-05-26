# frozen_string_literal: true

# Cross-stream synchronous handler: propagates a framework version
# publish to every PersonDev stream assigned to the framework so their
# ratings / evidence / comments follow the migration mappings onto the
# new survivor capabilities.
#
# When `Frameworks::Events::FrameworkVersionPublished` lands, this
# handler reads `FrameworkState::MigrationMapping` rows stamped at the
# new published version, enumerates every `PersonFrameworkAssignment`
# under the framework, and dispatches a `migrate_framework_version`
# command per person. The PersonDev aggregate records a single
# `FrameworkVersionMigrated` event per stream carrying the mappings and
# the per-capability counts that the projections and the activity feed
# both consume.
#
# IMPORTANT INVARIANTS
# ====================
#
# 1. **Same transaction as originator**: registered via
#    `event_store.subscribe` so each PersonDev command runs inline with
#    the publish. A failure rolls back the publish — better to refuse
#    the version than partially migrate.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches
#    commands, not just read-model writes. Register as a subscription,
#    not a projection. The PersonDev aggregate's idempotency check
#    (`@last_migrated_to_version`) means an accidental replay is a
#    no-op, but the registry guard at
#    `test/lib/projections/registry_test.rb` keeps it out of the
#    rebuild list at the source.
#
# 3. **No-op when no mappings exist**: a publish with no archived
#    capabilities (e.g. a description-only edit) has no mappings to
#    propagate. The handler bails before touching any person stream.
#
# 4. **Subscription order**: `PublishedState` is subscribed first in
#    `config/initializers/rails_event_store.rb` so its
#    `rebuild_framework_projection` finishes before this handler reads
#    the freshly-rebuilt read models.
#
class Frameworks::SyncHandlers::FrameworkVersionMigrationSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [ Frameworks::Events::FrameworkVersionPublished ]
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
    new_version  = event.data[:version]
    old_version  = new_version - 1

    mappings = FrameworkState::MigrationMapping
      .where(framework_id: framework_id, published_version: new_version)
      .to_a

    return if mappings.empty?

    # Resolve capability names once for every from/to stable_id appearing
    # in this batch, then drop them into per-person payloads as we go.
    name_by_stable_id = capability_names_for(mappings)

    assignments = PersonFrameworkAssignment
      .where(framework_id: framework_id)
      .pluck(:person_id)

    assignments.each do |person_id|
      payload = build_payload(person_id, framework_id, mappings, name_by_stable_id)
      command_handler.migrate_framework_version(
        person_id, framework_id, old_version, new_version, payload
      )
    end
  end

  # Returns the array shape expected by
  # `PersonDevelopment::Events::FrameworkVersionMigrated`: one entry per
  # mapping, with per-person counts so the activity feed entries and
  # projection updates need no extra DB joins.
  def build_payload(person_id, framework_id, mappings, name_by_stable_id)
    mappings.map do |mapping|
      counts = counts_for(person_id, framework_id, mapping.from_stable_id)
      {
        from_stable_id: mapping.from_stable_id,
        to_stable_id: mapping.to_stable_id,
        mapping_type: mapping.mapping_type,
        requires_reassessment: mapping.requires_reassessment,
        from_capability_name: name_by_stable_id[mapping.from_stable_id],
        to_capability_name: mapping.to_stable_id && name_by_stable_id[mapping.to_stable_id],
        counts: counts
      }
    end
  end

  def counts_for(person_id, framework_id, from_stable_id)
    {
      ratings: AssessmentLevelRating.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: from_stable_id
      ).count,
      evidence: EvidenceItem.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: from_stable_id
      ).count,
      comments: PersonDevelopmentComment.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: from_stable_id
      ).count
    }
  end

  def capability_names_for(mappings)
    stable_ids = mappings.flat_map { |m| [ m.from_stable_id, m.to_stable_id ] }.compact.uniq
    FrameworkState::Capability.where(stable_id: stable_ids).pluck(:stable_id, :name).to_h
  end

  def command_handler
    @command_handler ||= PersonDevelopment::CommandHandler.new
  end
end
