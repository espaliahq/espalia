# frozen_string_literal: true

# Projection read model for one (capability_stable_id, level_ordinal) link
# of an evidence item. A single {EvidenceItem} can demonstrate several
# capability × level expectations, so it has one EvidenceLink per cell it
# appears in.
#
# Materialised from PersonDevelopment evidence events
# ({EvidenceRecorded} — the first link, {EvidenceLinkAdded},
# {EvidenceLinkRemoved}, historical {EvidenceRelinked}) by
# {PersonDevelopment::Projections::EvidenceCollection}, which owns this
# table exclusively.
#
# Anchored to the same `(capability_stable_id, level_ordinal)` coordinate
# as ratings — links accompany the behavioural expectation, not a
# particular role's level UUID — so they stay stable across role
# transitions and framework versions.
#
# Removed links remain in the table with `link_status: "removed"` so audit
# history is preserved. The assessment matrix uses the {.active} scope.
# Item-level withdrawal (on {EvidenceItem}) hides ALL of an item's links;
# `link_status: "removed"` here hides only that one cell.
#
class EvidenceLink < ApplicationRecord
  LINK_STATUSES = %w[active removed].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :evidence_item, foreign_key: :evidence_id, inverse_of: :evidence_links, optional: false
  belongs_to :linked_by, class_name: "Person", foreign_key: :linked_by_id, inverse_of: false, optional: true
  belongs_to :removed_by, class_name: "Person", foreign_key: :removed_by_id, inverse_of: false, optional: true

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :capability_stable_id, presence: true
  validates :level_ordinal, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :link_status, presence: true, inclusion: { in: LINK_STATUSES }
  validates :linked_at, presence: true

  scope :active, -> { where(link_status: "active") }
  scope :removed, -> { where(link_status: "removed") }
  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :for_capability, ->(stable_id) { where(capability_stable_id: stable_id) }
  scope :at_level, ->(ordinal) { where(level_ordinal: ordinal) }
  scope :for_cell, ->(stable_id, ordinal) { where(capability_stable_id: stable_id, level_ordinal: ordinal) }

  # Whether this link has been removed.
  #
  # @return [Boolean]
  def removed?
    link_status == "removed"
  end
end
