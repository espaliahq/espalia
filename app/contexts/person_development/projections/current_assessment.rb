# frozen_string_literal: true

# Synchronous projection that materialises per-level capability assessment ratings
# and per-cycle journey progress.
#
# Subscribes to PersonDevelopment aggregate events and writes to three
# read models, all owned exclusively by this projection:
#
# * `PersonFrameworkAssignment` — the person's role / level assignment.
# * `AssessmentLevelRating` — one row per (cycle_id, person, framework,
#   capability_stable_id, level_ordinal).
# * `AssessmentCycleProgress` — per-cycle journey: started_at, alignment
#   timestamps, terminal aligned state.
#
# Because rating rows are scoped by cycle, historical ratings across
# cycles are preserved rather than overwritten.
#
# Membership in a cycle (enrolled / withdrawn) lives on the sibling
# {AssessmentCycleEnrollment} table, owned by
# {AssessmentCycles::Projections::CurrentState}. The two are joined for
# read sites via {AssessmentCycleParticipation}.
#
class PersonDevelopment::Projections::CurrentAssessment
  # Stable identifier used as the natural key in `projection_versions.name`.
  # See `docs/guidelines/event-sourcing.md` for the projection contract.
  PROJECTION_NAME = "person_development/current_assessment"

  # Bump when `reset!` or any handler in this projection would write
  # different state from the same event payload than before.
  #
  # 2 — handles `FrameworkVersionMigrated`: rewrites `capability_stable_id`
  #     on rating rows for `same`/`evolved` mappings and stamps
  #     `migration_status`/`reassessment_reason` for the rest.
  # 3 — `FrameworkVersionMigrated` now FREEZES completed assessments: rating
  #     rows belonging to a cycle the person has aligned are no longer
  #     re-keyed/flagged. A rebuild therefore reverts any completed-cycle rows
  #     that earlier code had migrated — so this bump requires a rebuild
  #     (REBUILD_ON_DEPLOY=person_development/current_assessment).
  #
  # Not bumped for `manager_rated_by_id` / `aligned_by_id` /
  # `aligned_framework_version`: historical ManagerRated/Revised,
  # AssessmentAligned, and FullAlignmentCompleted events carry no value for
  # these, so a rebuild writes nil — identical to the column defaults.
  CODE_VERSION = 4

  # All event classes this projection handles.
  #
  # @return [Array<Class>] event classes
  def self.handled_events
    [
      PersonDevelopment::Events::PersonAssignedToFramework,
      PersonDevelopment::Events::PersonRoleChanged,
      PersonDevelopment::Events::PersonLevelChanged,
      PersonDevelopment::Events::JoinedAssessmentCycle,
      PersonDevelopment::Events::LeftAssessmentCycle,
      PersonDevelopment::Events::SelfRated,
      PersonDevelopment::Events::SelfRatingRevised,
      PersonDevelopment::Events::SelfRatingCleared,
      PersonDevelopment::Events::ManagerRated,
      PersonDevelopment::Events::ManagerRatingRevised,
      PersonDevelopment::Events::ManagerRatingCleared,
      PersonDevelopment::Events::AlignmentStarted,
      PersonDevelopment::Events::AssessmentAligned,
      PersonDevelopment::Events::AlignmentCleared,
      PersonDevelopment::Events::FullAlignmentCompleted,
      PersonDevelopment::Events::FrameworkVersionMigrated
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  # Idempotent. Each table is owned exclusively by this projection. Wrapped
  # in tenant context so callers don't have to remember.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      PersonFrameworkAssignment.where(tenant_id: tenant.id).delete_all
      AssessmentLevelRating.where(tenant_id: tenant.id).delete_all
      AssessmentCycleProgress.where(tenant_id: tenant.id).delete_all
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
    when PersonDevelopment::Events::PersonAssignedToFramework then handle_assigned(event)
    when PersonDevelopment::Events::PersonRoleChanged then handle_role_changed(event)
    when PersonDevelopment::Events::PersonLevelChanged then handle_level_changed(event)
    when PersonDevelopment::Events::JoinedAssessmentCycle then handle_joined_cycle(event)
    when PersonDevelopment::Events::LeftAssessmentCycle then handle_left_cycle(event)
    when PersonDevelopment::Events::SelfRated then handle_self_rated(event)
    when PersonDevelopment::Events::SelfRatingRevised then handle_self_rating_revised(event)
    when PersonDevelopment::Events::SelfRatingCleared then handle_self_rating_cleared(event)
    when PersonDevelopment::Events::ManagerRated then handle_manager_rated(event)
    when PersonDevelopment::Events::ManagerRatingRevised then handle_manager_rating_revised(event)
    when PersonDevelopment::Events::ManagerRatingCleared then handle_manager_rating_cleared(event)
    when PersonDevelopment::Events::AlignmentStarted then handle_alignment_started(event)
    when PersonDevelopment::Events::AssessmentAligned then handle_assessment_aligned(event)
    when PersonDevelopment::Events::AlignmentCleared then handle_alignment_cleared(event)
    when PersonDevelopment::Events::FullAlignmentCompleted then handle_full_alignment_completed(event)
    when PersonDevelopment::Events::FrameworkVersionMigrated then handle_framework_version_migrated(event)
    end
  end

  # Applies the migration mappings carried on `FrameworkVersionMigrated`
  # to this person's rating rows for the migrated framework.
  #
  # * `same` / `evolved` → re-key the row to the survivor's `to_stable_id`.
  #   `evolved` with `requires_reassessment: true` also gets the
  #   `migration_status` flag.
  # * `archived` / `split` → leave the row pointing at the archived
  #   `from_stable_id` and flag it via `migration_status`. The matrix
  #   builder filters archived capabilities, so the row is invisible
  #   until the future relink/dismiss UI surfaces it.
  # * `new` → no predecessor row to touch.
  #
  # **Completed assessments are frozen**: rows belonging to a cycle this person
  # has aligned are never re-keyed or flagged — a completed assessment is an
  # immutable record, viewed as-at-completion (see the freeze-vs-migrate
  # decision). The frozen set is read from `AssessmentCycleProgress` (status
  # "aligned"), which this projection also owns, so it's replay-safe: a cycle
  # aligned BEFORE this migration in stream order is frozen; one aligned after
  # is migrated normally (it was in-progress when the version published).
  #
  # Idempotent: never downgrades an existing flag (the
  # `WHERE migration_status = 'not_flagged'` clause). Re-keying an
  # already-re-keyed row is a no-op (the WHERE clause won't match).
  def handle_framework_version_migrated(event)
    person_id = event.metadata[:person_id]
    framework_id = event.data[:framework_id]
    frozen_cycle_ids = aligned_cycle_ids(person_id)

    event.data[:mappings].each do |mapping|
      scope = AssessmentLevelRating.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: mapping[:from_stable_id]
      )
      scope = scope.where.not(cycle_id: frozen_cycle_ids) if frozen_cycle_ids.any?

      case mapping[:mapping_type]
      when "same"
        scope.update_all(capability_stable_id: mapping[:to_stable_id])
      when "evolved"
        scope.update_all(capability_stable_id: mapping[:to_stable_id])
        if mapping[:requires_reassessment]
          flag_scope = AssessmentLevelRating
            .where(person_id: person_id, framework_id: framework_id,
                   capability_stable_id: mapping[:to_stable_id],
                   migration_status: "not_flagged")
          flag_scope = flag_scope.where.not(cycle_id: frozen_cycle_ids) if frozen_cycle_ids.any?
          flag_scope.update_all(migration_status: "flagged",
                                reassessment_reason: "expectations_evolved")
        end
      when "archived"
        scope.where(migration_status: "not_flagged")
          .update_all(migration_status: "flagged",
                      reassessment_reason: "capability_archived")
      when "split"
        scope.where(migration_status: "not_flagged")
          .update_all(migration_status: "flagged",
                      reassessment_reason: "capability_split")
      when "new"
        # No predecessor data on this stream — nothing to migrate.
      end
    end
  end

  # Cycle ids this person has aligned (completed) — their rating rows are
  # frozen from migration. Read from the projection's own
  # `AssessmentCycleProgress` table (status "aligned"), keeping the frozen-set
  # determination replay-safe. A cycle_id is unique to a framework, so no
  # framework filter is needed — the caller's scope is already framework-bound.
  #
  # @param person_id [String]
  # @return [Array<String>] frozen cycle ids
  def aligned_cycle_ids(person_id)
    AssessmentCycleProgress.where(person_id: person_id, status: "aligned").pluck(:cycle_id)
  end

  def handle_assigned(event)
    PersonFrameworkAssignment.find_or_initialize_by(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id]
    ).tap do |assignment|
      assignment.role_id = event.data[:role_id]
      assignment.level_id = event.data[:level_id]
      assignment.save!
    end
  end

  def handle_role_changed(event)
    assignment = find_assignment(event)
    return unless assignment

    assignment.update!(
      role_id: event.data[:new_role_id],
      level_id: event.data[:new_level_id]
    )
  end

  def handle_level_changed(event)
    assignment = find_assignment(event)
    return unless assignment

    assignment.update!(level_id: event.data[:new_level_id])
  end

  # On (re-)joining a cycle:
  #   1. Wipe any stale AssessmentLevelRating rows for this (cycle, person).
  #      The aggregate's `JoinedAssessmentCycle` on-handler resets in-memory
  #      rating state to fresh, so the read model must mirror that.
  #   2. Upsert the AssessmentCycleProgress row to a fresh state (status
  #      `in_progress`, all journey columns nil). Re-joining clears any
  #      historical progress from a prior enrollment in the same cycle —
  #      a fresh enrollment is a fresh journey.
  def handle_joined_cycle(event)
    AssessmentLevelRating.where(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id]
    ).delete_all

    progress = AssessmentCycleProgress.find_or_initialize_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id]
    )
    progress.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      status: "in_progress",
      started_at: nil,
      self_completed_at: nil,
      manager_completed_at: nil,
      alignment_started_at: nil,
      alignment_started_by_id: nil,
      aligned_at: nil,
      aligned_by_id: nil
    )
    progress.save!
  end

  def handle_left_cycle(_event)
    # Intentional no-op: keep the progress row as a historical record of
    # how far the person got. Active-participant queries already filter
    # via the enrollment row's status flipping to "withdrawn"; the orphaned
    # progress row doesn't leak into active views.
  end

  def handle_self_rated(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    apply_source(rating, event)
    rating.save!
    touch_progress_started(event) unless seeded_event?(event)
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_self_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.source = "human"
    rating.save!
    touch_progress_started(event)
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_self_rating_cleared(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = nil
    rating.self_rated_comment = nil
    rating.save!
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rated(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.manager_rated_by_id = event.data[:rated_by_id]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    apply_source(rating, event)
    rating.save!
    touch_progress_started(event) unless seeded_event?(event)
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.manager_rated_by_id = event.data[:rated_by_id]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    rating.source = "human"
    rating.save!
    touch_progress_started(event)
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rating_cleared(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = nil
    rating.manager_rated_comment = nil
    rating.manager_rated_by_id = nil
    rating.save!
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_alignment_started(event)
    progress = find_progress(event)
    return unless progress

    now = event.metadata[:timestamp] || Time.current
    progress.update!(
      status: "aligning",
      alignment_started_at: now,
      alignment_started_by_id: event.data[:started_by_id],
      started_at: progress.started_at || now
    )
    broadcast_assessment_sync(event)
  end

  def handle_assessment_aligned(event)
    rating = find_or_init_rating(event)
    rating.aligned_frequency = event.data[:aligned_frequency]
    rating.aligned_comment = event.data[:comment]
    rating.aligned_by_id = event.data[:aligned_by_id]
    rating.last_aligned_at = event.metadata[:timestamp] || Time.current
    rating.save!
    broadcast_assessment_sync(event)
  end

  def handle_alignment_cleared(event)
    # find-only, never init: if no rating row exists for this (cycle,
    # person, capability, level) there is nothing to clear, and
    # inserting a fresh all-nil row would pollute reads and broadcast
    # spurious sync events. AssessmentAligned is the only path that
    # creates an aligned row, and the aggregate's
    # `clear_alignment_rating` guard requires a prior alignment in the
    # same cycle — so the only way this branch fires without a row is
    # via a replay or out-of-band event we should ignore.
    rating = AssessmentLevelRating.find_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal]
    )
    return unless rating

    rating.aligned_frequency = nil
    rating.aligned_comment = nil
    rating.aligned_by_id = nil
    rating.save!
    broadcast_assessment_sync(event)
  end

  def handle_full_alignment_completed(event)
    progress = find_progress(event)
    return unless progress

    now = event.metadata[:timestamp] || Time.current
    progress.update!(
      status: "aligned",
      aligned_at: now,
      aligned_by_id: event.data[:completed_by_id],
      aligned_framework_version: event.data[:framework_version]
    )
    broadcast_assessment_sync(event)
  end

  # Whether the rating event was emitted as part of a seeding flow.
  #
  # @param event [RubyEventStore::Event]
  # @return [Boolean]
  def seeded_event?(event)
    event.data[:source] == "seeded"
  end

  # Sets the rating's source attribution.
  # New seeded rating → source: "seeded", seeded_from_cycle_id stamped.
  # Human entry on a previously-seeded row → source flips to "human".
  # Default: "human" (unchanged for legacy rows).
  #
  # @param rating [AssessmentLevelRating]
  # @param event [RubyEventStore::Event]
  def apply_source(rating, event)
    if seeded_event?(event)
      rating.source = "seeded" if rating.new_record? || rating.source != "human"
      rating.seeded_from_cycle_id ||= event.data[:seeded_from_cycle_id]
    else
      rating.source = "human"
    end
  end

  # Finds or initialises an AssessmentLevelRating for the (cycle, person,
  # framework, capability_stable_id, level_ordinal) composite key.
  #
  # @param event [RubyEventStore::Event]
  # @return [AssessmentLevelRating]
  def find_or_init_rating(event)
    AssessmentLevelRating.find_or_initialize_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal]
    )
  end

  # Finds the PersonFrameworkAssignment for the event's person and framework.
  #
  # @param event [RubyEventStore::Event]
  # @return [PersonFrameworkAssignment, nil]
  def find_assignment(event)
    PersonFrameworkAssignment.find_by(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id]
    )
  end

  # Finds the AssessmentCycleProgress row for the event's cycle and person.
  #
  # @param event [RubyEventStore::Event]
  # @return [AssessmentCycleProgress, nil]
  def find_progress(event)
    AssessmentCycleProgress.find_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id]
    )
  end

  # Sets the progress row's started_at if not already set.
  #
  # @param event [RubyEventStore::Event] a rating event carrying cycle_id
  def touch_progress_started(event)
    progress = find_progress(event)
    return unless progress
    return if progress.started_at.present?

    now = event.metadata[:timestamp] || Time.current
    progress.update_columns(
      started_at: now,
      status: "started",
      updated_at: now
    )
  end

  # Recomputes current-level coverage for both perspectives after a rating
  # change and stamps the per-side completion timestamps the /assessments list
  # reads. `status` is left as the lifecycle phase — completion lives in the
  # two timestamp columns because the two sides complete independently.
  #
  # The original completion time is preserved across later edits that stay
  # complete; the timestamp is cleared the moment coverage drops below complete.
  # Replay-safe (no broadcast).
  #
  # Known limitation: a FrameworkVersionMigrated that changes the current-level
  # cell set without a subsequent rating can leave a stale flag until the next
  # rating — acceptable while migrations are rare and the migration UI is
  # deferred.
  def refresh_completion(event)
    progress = find_progress(event)
    return unless progress

    coverage = Assessments::LevelCoverage.new(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      cycle_id: event.data[:cycle_id]
    ).call
    now = event.metadata[:timestamp] || Time.current

    progress.update_columns(
      self_completed_at: completion_timestamp(progress.self_completed_at, coverage[:self_complete], now),
      manager_completed_at: completion_timestamp(progress.manager_completed_at, coverage[:manager_complete], now),
      updated_at: now
    )
  end

  # @return [Time, nil] existing time if still complete, `now` on first
  #   completion, nil when not complete.
  def completion_timestamp(existing, complete, now)
    return nil unless complete

    existing || now
  end

  # Broadcasts a sync signal to all viewers of this assessment.
  # The signal triggers a matrix frame reload via the matrix Stimulus controller.
  #
  # Suppressed during replay (see `Projections::Replayer.replay_mode?`) to
  # avoid spamming live Turbo channels during a rebuild.
  #
  # @param event [RubyEventStore::Event]
  def broadcast_assessment_sync(event)
    return if Projections::Replayer.replay_mode?

    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    # Don't let broadcast failures break the projection
    Rails.logger.warn("[CurrentAssessment] Broadcast failed: #{e.message}")
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
