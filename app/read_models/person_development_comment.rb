# frozen_string_literal: true

# Projection read model for comments on a person's development stream.
#
# A first-class citizen of the person development domain — initial V1
# anchors comments to (capability_stable_id, level_ordinal) coordinates
# on the assessment matrix. Future commentable types (growth plans,
# focus areas, check-ins) will reuse this table by setting
# `commentable_type` to the new type and leaving the cell-coordinate
# columns nullable.
#
# Comments are addressable by id (UUID v7), so other domain objects —
# notably {EvidenceItem} — can later link to a comment as evidence
# of a behaviour.
#
# Soft-delete: deleted comments stay in the table with `status: "deleted"`
# so reply chains remain coherent and any references to them resolve.
#
class PersonDevelopmentComment < ApplicationRecord
  ASSESSMENT_CELL = "assessment_cell"
  COMMENTABLE_TYPES = [ ASSESSMENT_CELL ].freeze
  STATUSES = %w[active deleted].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :author, class_name: "Person", foreign_key: :author_id, inverse_of: false, optional: false
  belongs_to :edited_by, class_name: "Person", foreign_key: :edited_by_id, inverse_of: false, optional: true
  belongs_to :deleted_by, class_name: "Person", foreign_key: :deleted_by_id, inverse_of: false, optional: true
  belongs_to :parent, class_name: "PersonDevelopmentComment",
             foreign_key: :parent_id, inverse_of: :replies, optional: true
  has_many :replies, class_name: "PersonDevelopmentComment",
           foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_exception

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :commentable_type, presence: true, inclusion: { in: COMMENTABLE_TYPES }
  validates :body, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :posted_at, presence: true
  validates :capability_stable_id, presence: true,
            if: -> { commentable_type == ASSESSMENT_CELL }
  validates :level_ordinal, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 },
            if: -> { commentable_type == ASSESSMENT_CELL }

  scope :active, -> { where(status: "active") }
  scope :deleted, -> { where(status: "deleted") }
  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :on_cell, ->(capability_stable_id, level_ordinal) do
    where(commentable_type: ASSESSMENT_CELL,
          capability_stable_id: capability_stable_id,
          level_ordinal: level_ordinal)
  end
  scope :top_level, -> { where(parent_id: nil) }
  scope :chronological, -> { order(:posted_at) }

  # Whether this comment has been soft-deleted.
  #
  # @return [Boolean]
  def deleted?
    status == "deleted"
  end
end
