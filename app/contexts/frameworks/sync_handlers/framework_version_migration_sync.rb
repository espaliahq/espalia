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

    assignments = PersonFrameworkAssignment
      .where(framework_id: framework_id)
      .pluck(:person_id)
    return if assignments.empty?

    name_by_stable_id = capability_names_for(mappings)
    from_ids = mappings.map(&:from_stable_id).uniq

    # Three batched GROUP BY queries instead of 3 × N people × M mappings
    # individual COUNTs. Critical because the sync handler runs in the
    # same transaction as the publish — slow queries here block every
    # publish of every framework.
    ratings_by_person  = grouped_counts(AssessmentLevelRating,    assignments, framework_id, from_ids)
    evidence_by_person = grouped_counts(EvidenceItem,             assignments, framework_id, from_ids)
    comments_by_person = grouped_counts(PersonDevelopmentComment, assignments, framework_id, from_ids)

    assignments.each do |person_id|
      payload = build_payload(person_id, mappings, name_by_stable_id,
                              ratings_by_person, evidence_by_person, comments_by_person)
      command_handler.migrate_framework_version(
        person_id, framework_id, old_version, new_version, payload
      )
    end
  end

  # Returns the array shape expected by
  # `PersonDevelopment::Events::FrameworkVersionMigrated`: one entry per
  # mapping, with per-person counts so the activity feed entries and
  # projection updates need no extra DB joins.
  def build_payload(person_id, mappings, name_by_stable_id,
                    ratings_by_person, evidence_by_person, comments_by_person)
    mappings.map do |mapping|
      key = [ person_id, mapping.from_stable_id ]
      {
        from_stable_id: mapping.from_stable_id,
        to_stable_id: mapping.to_stable_id,
        mapping_type: mapping.mapping_type,
        requires_reassessment: mapping.requires_reassessment,
        from_capability_name: name_by_stable_id[mapping.from_stable_id],
        to_capability_name: mapping.to_stable_id && name_by_stable_id[mapping.to_stable_id],
        counts: {
          ratings:  ratings_by_person.fetch(key, 0),
          evidence: evidence_by_person.fetch(key, 0),
          comments: comments_by_person.fetch(key, 0)
        }
      }
    end
  end

  # Returns `{ [person_id, capability_stable_id] => count }` via a single
  # GROUP BY query. Persons with no rows for any from_stable_id are
  # absent — the caller defaults missing keys to 0.
  def grouped_counts(model, person_ids, framework_id, from_ids)
    model
      .where(person_id: person_ids, framework_id: framework_id, capability_stable_id: from_ids)
      .group(:person_id, :capability_stable_id)
      .count
  end

  def capability_names_for(mappings)
    stable_ids = mappings.flat_map { |m| [ m.from_stable_id, m.to_stable_id ] }.compact.uniq
    FrameworkState::Capability.where(stable_id: stable_ids).pluck(:stable_id, :name).to_h
  end

  def command_handler
    @command_handler ||= PersonDevelopment::CommandHandler.new
  end
end
