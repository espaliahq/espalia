# frozen_string_literal: true

require "zlib"

# Records the last `CODE_VERSION` at which each replayable projection was
# globally rebuilt. The predeploy guard (`events:projections:verify`) compares
# this against the projection class's current `CODE_VERSION` constant to fail
# deploys that ship new projection logic without a rebuild.
#
# Global (not tenant-scoped) — `name` is the natural primary key.
#
# See:
#   * [docs/runbooks/projection-rebuild.md](docs/runbooks/projection-rebuild.md)
#   * [docs/guidelines/event-sourcing.md](docs/guidelines/event-sourcing.md)
#
class ProjectionVersion < ApplicationRecord
  # A write refused by {.unless_rebuilding}. Operations show its message.
  class Rebuilding < StandardError
    def initialize(message = "The Org Graph is being rebuilt; try again in a minute.") = super
  end

  self.primary_key = :name

  validates :name,    presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Records that `projection_class` has been rebuilt at its current
  # `CODE_VERSION`. Idempotent.
  #
  # @param projection_class [Class] a class declaring `PROJECTION_NAME` and
  #   `CODE_VERSION` constants
  # @return [ProjectionVersion]
  def self.stamp!(projection_class)
    upsert(
      { name: projection_class::PROJECTION_NAME, version: projection_class::CODE_VERSION, applied_at: Time.current },
      unique_by: :name
    )
    find(projection_class::PROJECTION_NAME)
  end

  # Serialises every operation that reads or writes a projection's stamp — a
  # rebuild (reset, replay, restamp), the predeploy stale check that decides
  # whether to rebuild, and a Path B promotion — on one session-level
  # Postgres advisory lock per projection. Without it a promotion landing
  # between a rebuild's stale check and its final `stamp!` is silently
  # overwritten by the lower version. Session-level (not transactional) so a
  # multi-minute replay is not wrapped in one transaction; the lock is
  # reentrant within a session, so a task may take it around a nested one.
  #
  # @param name [String] a `PROJECTION_NAME`
  # @yield while the lock is held
  # @return [Object] the block's value
  def self.with_operation_lock(name)
    key = lock_key(name)
    connection.select_value(sanitize_sql_array([ "SELECT pg_advisory_lock(?)", key ]))
    yield
  ensure
    connection.select_value(sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", key ]))
  end

  # {.with_operation_lock} on several projections at once, taken in name
  # order, so two callers that each take several cannot deadlock.
  #
  # @param names [Array<String>]
  # @yield while every lock is held
  # @return [Object] the block's value
  def self.with_operation_locks(names, &block)
    names.sort.reverse.reduce(block) { |inner, name| -> { with_operation_lock(name, &inner) } }.call
  end

  # Runs a write that plans from these projections' tables, unless one of
  # them is being rebuilt. A rebuild holds {.with_operation_lock} from its
  # first reset to its final stamp, so its tables are empty or half replayed
  # throughout; a write that read them then would decide from a wrong list.
  # Shares the same key, so the write refuses at once, and a rebuild that
  # starts meanwhile waits for it to finish.
  #
  # @param names [Array<String>] `PROJECTION_NAME`s
  # @yield while no rebuild can start
  # @return [Object] the block's value
  # @raise [Rebuilding] when a rebuild holds any of them
  def self.unless_rebuilding(*names)
    held = []
    names.each do |name|
      key = lock_key(name)
      raise Rebuilding unless connection.select_value(sanitize_sql_array([ "SELECT pg_try_advisory_lock_shared(?)", key ]))

      held << key
    end
    yield
  ensure
    held&.each { connection.select_value(sanitize_sql_array([ "SELECT pg_advisory_unlock_shared(?)", it ])) }
  end

  # @param name [String]
  # @return [Integer] a stable 32-bit key for the advisory lock
  def self.lock_key(name)
    Zlib.crc32("projection_versions:#{name}")
  end

  # Moves a projection's stamp forward to `version` — never backwards — in one
  # statement, so two concurrent promotions cannot leave the lower one in
  # place. Used by the runbook's Path B to declare an out-of-band rebuild as
  # the version the coming CODE_VERSION bump will carry.
  #
  # @param name [String] a `PROJECTION_NAME`
  # @param version [Integer] non-negative target version
  # @return [ProjectionVersion] the row as it stands after the call
  # @raise [ArgumentError] for a negative version
  def self.promote!(name, version)
    raise ArgumentError, "version must be a non-negative integer, got #{version.inspect}" unless
      version.is_a?(Integer) && version >= 0

    with_operation_lock(name) do
      upsert(
        { name: name, version: version, applied_at: Time.current },
        unique_by: :name,
        on_duplicate: Arel.sql(<<~SQL.squish)
          version = GREATEST(projection_versions.version, EXCLUDED.version),
          applied_at = CASE WHEN EXCLUDED.version > projection_versions.version
                            THEN EXCLUDED.applied_at ELSE projection_versions.applied_at END
        SQL
      )
      find(name)
    end
  end
end
