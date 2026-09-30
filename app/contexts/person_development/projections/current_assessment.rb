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
#   timestamps, terminal aligned state — the HOME role's lifecycle.
# * `AssessmentCycleRoleAlignment` — one row per role alignment has been
#   started against in a cycle, the home role included (ADR-22).
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
  #
  # Not bumped for `PersonUnassignedFromFramework`: a brand-new event type
  # with zero historical instances in the stream, so a rebuild produces
  # identical state (additive handler, `reset!` truncate set unchanged).
  #
  # 5 — `PersonFrameworkAssignment` now derives its primary key
  #     deterministically from `(person_id, framework_id)` via
  #     {DeterministicId}, instead of a random `uuid_v7` minted at projection
  #     time. A rebuild therefore re-keys every assignment row to its
  #     deterministic id (one-time PK churn; thereafter stable across all
  #     rebuilds). Requires a rebuild
  #     (REBUILD_ON_DEPLOY=person_development/current_assessment).
  #
  # 6 — per-side rating provenance: rating handlers now stamp
  #     `self_rating_source` / `manager_rating_source` ("seeded" | "human";
  #     a clear stamps "human" with a nil frequency — the human owns the
  #     emptiness, which stops seed re-runs resurrecting deliberate
  #     clears; nil means the side never held anything) so the UI can
  #     render carried-forward ratings distinctly per perspective — the
  #     row-level `source` flips to "human" on ANY human touch and can't
  #     tell which side is still carried. Derivable from historical
  #     events → rebuild backfills
  #     (REBUILD_ON_DEPLOY=person_development/current_assessment).
  #
  # 7 — completion means VETTED: `refresh_completion` (via
  #     Assessments::LevelCoverage) no longer counts carried-forward
  #     (seeded, unconfirmed) sides toward `self_completed_at` /
  #     `manager_completed_at` — the list's Complete chips and the
  #     Ready-to-align cue were reading fully-carried assessments as done.
  #     A rebuild retro-clears completion stamps that were earned by
  #     seeds alone (REBUILD_ON_DEPLOY=person_development/current_assessment).
  #
  # 8 — per-role alignment (ADR-22): writes `AssessmentCycleRoleAlignment`,
  #     one row per role alignment has started against, and a rebuild
  #     backfills the home role's rows from every historical alignment
  #     event. Only a start against the home role moves
  #     `AssessmentCycleProgress`. And `started` now means a human rating on
  #     a cell the home role reads: a rating only another role reads (made
  #     through a lens) no longer flips a participation to `started`, so a
  #     rebuild can revert such a participation to `enrolled`
  #     (REBUILD_ON_DEPLOY=person_development/current_assessment).
  CODE_VERSION = 8

  # All event classes this projection handles.
  #
  # @return [Array<Class>] event classes
  def self.handled_events
    [
      PersonDevelopment::Events::PersonAssignedToFramework,
      PersonDevelopment::Events::PersonRoleChanged,
      PersonDevelopment::Events::PersonLevelChanged,
      PersonDevelopment::Events::PersonUnassignedFromFramework,
      PersonDevelopment::Events::JoinedAssessmentCycle,
      PersonDevelopment::Events::LeftAssessmentCycle,
      PersonDevelopment::Events::AssessmentCycleConcluded,
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
      PersonDevelopment::Events::AlignmentReopened,
      PersonDevelopment::Events::FrameworkVersionMigrated,
      PersonDevelopment::Events::RatingRevisitRequested
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
      AssessmentCycleRoleAlignment.where(tenant_id: tenant.id).delete_all
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
    when PersonDevelopment::Events::PersonUnassignedFromFramework then handle_unassigned(event)
    when PersonDevelopment::Events::JoinedAssessmentCycle then handle_joined_cycle(event)
    when PersonDevelopment::Events::LeftAssessmentCycle then handle_left_cycle(event)
    when PersonDevelopment::Events::AssessmentCycleConcluded then handle_cycle_concluded(event)
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
    when PersonDevelopment::Events::AlignmentReopened then handle_alignment_reopened(event)
    when PersonDevelopment::Events::FrameworkVersionMigrated then handle_framework_version_migrated(event)
    when PersonDevelopment::Events::RatingRevisitRequested then handle_rating_revisit_requested(event)
    end
  end

  # No read-model write — the revisit request is a stream-only fact the
  # activity feed reads directly (resolution is rating-change-based, at read
  # time). Handled here solely so the assessment feed updates live for a
  # rater who has the page open when a calibration session nudges them.
  def handle_rating_revisit_requested(event)
    broadcast_assessment_sync(event)
  end

  # Applies the migration mappings carried on `FrameworkVersionMigrated`
  # to this person's rating rows for the migrated framework.
  #
  # * `evolved` → re-key the row to the survivor's `to_stable_id`; with
  #   `requires_reassessment: true` the survivor's rows are flagged. Where the
  #   survivor is already rated at the same cycle/level the rows are merged —
  #   see `rekey_ratings`.
  # * `same` → carries no survivor (the operation forbids one), so the rows
  #   stay under their stable id. A self-mapping (rejected by the operation
  #   today, but possible in history) re-keys nothing and only flags — exactly
  #   what the pre-merge code did, so replay of any persisted event is
  #   unchanged.
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
  #
  # No `CODE_VERSION` bump for the merge: a colliding publish could never
  # commit before (the unique violation rolled the whole transaction back), so
  # no persisted `FrameworkVersionMigrated` event replays differently.
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
      when "same", "evolved"
        to_stable_id = mapping[:to_stable_id]
        next if to_stable_id.nil?

        rekey_ratings(scope, to_stable_id) unless to_stable_id == mapping[:from_stable_id]
        if mapping[:requires_reassessment]
          scope.rewhere(capability_stable_id: to_stable_id)
            .where(migration_status: "not_flagged")
            .update_all(migration_status: "flagged", reassessment_reason: "expectations_evolved")
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

  # Moves every rating in `scope` (rows keyed by the retiring capability) onto
  # `to_stable_id`, except where the survivor already holds a rating for the
  # same cycle and level — `idx_assessment_ratings_cycle_person_cap_level`
  # forbids two rows there.
  #
  # Merge rule — **nothing is lost**: the survivor's own row stays as it is
  # and the absorbed row stays under the retiring stable id, flagged
  # `capability_merged`, exactly as `archived`/`split` rows are. Both are
  # then invisible in the matrix (archived capabilities are filtered) until
  # the relink/dismiss UI surfaces them. This also keeps the read model
  # aligned with the aggregate, which never re-keys its rating maps.
  #
  # Two statements: re-key the non-colliding rows (NOT EXISTS), after which
  # whatever is still under the retiring id is by construction the colliding
  # set, flagged with a plain UPDATE. Both run against the same lazy scope,
  # so its frozen-cycle exclusion applies to both.
  #
  # @param scope [ActiveRecord::Relation<AssessmentLevelRating>] rows under the
  #   retiring capability, already filtered for this person/framework and
  #   with frozen cycles excluded
  # @param to_stable_id [String] survivor capability stable id
  def rekey_ratings(scope, to_stable_id)
    scope.where.not(<<~SQL.squish, to_stable_id).update_all(capability_stable_id: to_stable_id)
      EXISTS (
        SELECT 1 FROM assessment_level_ratings survivor
        WHERE survivor.person_id = assessment_level_ratings.person_id
          AND survivor.framework_id = assessment_level_ratings.framework_id
          AND survivor.cycle_id = assessment_level_ratings.cycle_id
          AND survivor.level_ordinal = assessment_level_ratings.level_ordinal
          AND survivor.capability_stable_id = ?
      )
    SQL
    scope.where(migration_status: "not_flagged")
      .update_all(migration_status: "flagged", reassessment_reason: "capability_merged")
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

  # Removes the assignment row entirely. The PersonUnassignedFromFramework
  # event is the durable audit trail; the read model only reflects "currently
  # assigned", so a hard delete keeps every assignment query clean. Idempotent
  # — a no-op if the row is already gone.
  def handle_unassigned(event)
    find_assignment(event)&.destroy!
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
    AssessmentCycleRoleAlignment.for_participation(
      cycle_id: event.data[:cycle_id], person_id: event.metadata[:person_id]
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

  def handle_cycle_concluded(_event)
    # Intentional no-op, mirroring handle_left_cycle: the progress row IS
    # the historical record of the concluded participation (aligned_at on
    # it drives next-cycle rating seeding). The enrollment row's status
    # flip to "concluded" is owned by AssessmentCycles::Projections::CurrentState.
  end

  def handle_self_rated(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    # Provenance only (ADR-22). Absent on every event before the lens, so a
    # replay writes the nil the column already holds — no rebuild needed.
    rating.self_rated_via_role_id = event.data[:via_role_id]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.self_rating_source = seeded_event?(event) ? "seeded" : "human"
    apply_source(rating, event)
    rating.save!
    touch_progress_started(event) unless seeded_event?(event)
    # Completion counts only vetted (human) cells, so a seeded event can
    # never change it — skip the ~8-query coverage pass (paid ~100× per
    # person at bulk enrollment, and again on every replay).
    refresh_completion(event) unless seeded_event?(event)
    broadcast_assessment_sync(event)
  end

  def handle_self_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.self_rated_via_role_id = event.data[:via_role_id]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.source = "human"
    rating.self_rating_source = "human"
    rating.save!
    touch_progress_started(event)
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_self_rating_cleared(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = nil
    rating.self_rated_comment = nil
    rating.self_rated_via_role_id = nil
    # "human", not nil: a clear is a human decision that this side is
    # EMPTY. nil means "never held anything" — the distinction is what
    # lets a seed re-run complete untouched sides without resurrecting
    # a value the person deliberately cleared.
    rating.self_rating_source = "human"
    rating.save!
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rated(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.manager_rated_via_role_id = event.data[:via_role_id]
    rating.manager_rated_by_id = event.data[:rated_by_id]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    rating.manager_rating_source = seeded_event?(event) ? "seeded" : "human"
    apply_source(rating, event)
    rating.save!
    touch_progress_started(event) unless seeded_event?(event)
    # See handle_self_rated — seeded events can't change vetted completion.
    refresh_completion(event) unless seeded_event?(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.manager_rated_via_role_id = event.data[:via_role_id]
    rating.manager_rated_by_id = event.data[:rated_by_id]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    rating.source = "human"
    rating.manager_rating_source = "human"
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
    rating.manager_rated_via_role_id = nil
    # "human", not nil — see handle_self_rating_cleared.
    rating.manager_rating_source = "human"
    rating.save!
    refresh_completion(event)
    broadcast_assessment_sync(event)
  end

  # A start with no role is history — the home role's, over every cell.
  def handle_alignment_started(event)
    now = event.metadata[:timestamp] || Time.current
    role_id = alignment_role_id(event)
    home = role_id == home_role_id(event)
    write_role_alignment(event, role_id) do |row|
      row.assign_attributes(
        home: home,
        whole_assessment: event.data[:cell_keys].nil?,
        level_ordinal: event.data[:level_ordinal] || (home_level_ordinal(event) if home),
        status: "aligning",
        alignment_started_at: now,
        alignment_started_by_id: event.data[:started_by_id],
        aligned_at: nil, aligned_by_id: nil, aligned_framework_version: nil,
        reopened_at: nil, reopened_by_id: nil
      )
    end

    progress = find_progress(event)
    if home && progress
      progress.update!(
        status: "aligning",
        alignment_started_at: now,
        alignment_started_by_id: event.data[:started_by_id],
        started_at: progress.started_at || now
      )
    end
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
    now = event.metadata[:timestamp] || Time.current
    role_id = alignment_role_id(event)
    update_role_alignment(event, role_id,
      status: "aligned", aligned_at: now, aligned_by_id: event.data[:completed_by_id],
      aligned_framework_version: event.data[:framework_version])

    progress = find_progress(event)
    if role_id == home_role_id(event) && progress
      progress.update!(
        status: "aligned",
        aligned_at: now,
        aligned_by_id: event.data[:completed_by_id],
        aligned_framework_version: event.data[:framework_version]
      )
    end
    broadcast_assessment_sync(event)
  end

  # Re-opens a completed alignment: returns the role to the `aligning`
  # phase and clears the completion stamps. The agreed per-cell values on
  # AssessmentLevelRating are deliberately left intact — the manager
  # resumes the conversation where it was left and re-completes when ready.
  # The original alignment_started_at / _by_id are preserved (the role was
  # already in alignment; we're only undoing the completion).
  def handle_alignment_reopened(event)
    role_id = alignment_role_id(event)
    update_role_alignment(event, role_id,
      status: "aligning", aligned_at: nil, aligned_by_id: nil, aligned_framework_version: nil,
      reopened_at: event.metadata[:timestamp] || Time.current,
      reopened_by_id: event.data[:reopened_by_id])

    progress = find_progress(event)
    if role_id == home_role_id(event) && progress
      progress.update!(
        status: "aligning",
        aligned_at: nil,
        aligned_by_id: nil,
        aligned_framework_version: nil
      )
    end
    broadcast_assessment_sync(event)
  end

  # The role an alignment event is about; nil on history, which is the home
  # role's.
  #
  # @return [String, nil]
  def alignment_role_id(event)
    event.data[:role_id] || home_role_id(event)
  end

  # The role the cycle assesses the person at: its enrollment snapshot, else
  # the assignment this projection owns — the same home every reader uses
  # ({Assessments::RoleScope.home_role_ids}).
  #
  # @return [String, nil]
  def home_role_id(event)
    Assessments::RoleScope.home_role_ids(
      cycle_id: event.data[:cycle_id], framework_id: event.metadata[:framework_id],
      person_ids: [ event.metadata[:person_id] ]
    )[event.metadata[:person_id]]
  end

  # @return [Integer, nil]
  def home_level_ordinal(event)
    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: event.data[:cycle_id], person_id: event.metadata[:person_id])
    return enrollment.level_ordinal if enrollment&.level_ordinal

    level_id = find_assignment(event)&.level_id
    level_id && FrameworkState::Level.find_by(level_id: level_id)&.ordinal
  end

  # Whether a rating's cell counts toward the record. A home role nobody can
  # read — an unknown role, or one binding nothing — can't rule a cell out,
  # so every rating counts, as before per-role alignment.
  #
  # @return [Boolean]
  def in_home_scope?(event)
    role_id = home_role_id(event)
    return true unless role_id

    scope = Assessments::RoleScope.for(role_id: role_id, framework_id: event.metadata[:framework_id])
    scope.empty? || scope.include?(event.data[:capability_stable_id], event.data[:level_ordinal])
  end

  # @yieldparam row [AssessmentCycleRoleAlignment]
  def write_role_alignment(event, role_id)
    return unless role_id

    row = AssessmentCycleRoleAlignment.find_or_initialize_by(
      cycle_id: event.data[:cycle_id], person_id: event.metadata[:person_id], role_id: role_id
    )
    row.tenant_id = event.metadata[:tenant_id]
    row.framework_id = event.metadata[:framework_id]
    yield row
    row.save!
  end

  def update_role_alignment(event, role_id, **attributes)
    return unless role_id

    AssessmentCycleRoleAlignment
      .find_by(cycle_id: event.data[:cycle_id], person_id: event.metadata[:person_id], role_id: role_id)
      &.update!(attributes)
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
  #
  # Only a rating the record reads starts the participation: a rating made
  # through a lens on a cell only another role reads is exploration, not
  # progress on the assessment of record (ADR-22).
  def touch_progress_started(event)
    progress = find_progress(event)
    return unless progress
    return if progress.started_at.present?
    return unless in_home_scope?(event)

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
