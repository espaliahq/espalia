# frozen_string_literal: true

# Projection read model for framework version migration mappings.
#
# Maps capability stable_ids between framework versions to enable
# assessment migration when frameworks evolve.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::MigrationMapping < ApplicationRecord
  self.table_name = "framework_migration_mappings"

  MAPPING_TYPES = %w[same evolved split archived new].freeze

  acts_as_tenant :tenant

  belongs_to :tenant

  validates :framework_id, presence: true
  validates :mapping_id, presence: true
  validates :published_version, presence: true
  validates :mapping_type, presence: true, inclusion: { in: MAPPING_TYPES }

  # The mappings recorded for a framework's open draft — stamped at
  # projection time with the version the draft will publish as.
  #
  # @param framework [FrameworkState::Framework]
  scope :for_draft, ->(framework) {
    where(framework_id: framework.framework_id, published_version: framework.draft_version)
  }
end
