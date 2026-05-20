# frozen_string_literal: true

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
end
