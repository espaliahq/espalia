# frozen_string_literal: true

# Projection read model for the CONTENT of a piece of evidence (type,
# title, body, external reference, author, audit fields).
#
# The (capability, level) coordinates an item appears in live on
# {EvidenceLink} — one item can demonstrate several capability × level
# expectations. The `capability_stable_id` / `level_ordinal` columns here
# are the item's ORIGIN link (where it was first recorded); the activity
# feed anchors evidence-recorded/withdrawn entries on them. The assessment
# matrix reads from {EvidenceLink} for the full set of cells.
#
# Both origin columns are nil for an item recorded UNPLACED — feedback
# volunteered without a capability in mind. It has no link rows until the
# recipient, their manager or the author places it (see the {.unplaced}
# scope); until then it appears on the hub, never in a cell. The first
# placement becomes the origin, so a placed-later item reads like any other.
#
# Materialised from PersonDevelopment evidence events
# ({EvidenceRecorded}, {EvidenceUpdated}, {EvidenceWithdrawn}, and the
# link/relink events that touch {EvidenceLink}) by
# {PersonDevelopment::Projections::EvidenceCollection}.
#
# Anchored to the same `(capability_stable_id, level_ordinal)` coordinate
# system as ratings — evidence accompanies the behavioural expectation it's
# evidence for, not a particular role's level UUID. This keeps evidence
# stable across role transitions and framework versions.
#
# Withdrawn evidence remains in the table with `link_status: "withdrawn"`
# so the activity feed can render it (struck-through) and audit history
# is preserved. Withdrawal hides the item in EVERY cell. Use the {.active}
# scope to count toward the in-cell evidence badge or evidence-density
# reporting.
#
class EvidenceItem < ApplicationRecord
  SOURCES = %w[self manager peer].freeze
  FEEDBACK_DIRECTIONS = %w[
    manager_to_report
    peer_to_peer
    report_to_manager
    self
  ].freeze
  EVIDENCE_TYPES = %w[
    peer_feedback
    manager_feedback
    customer_feedback
    impact
    project_outcome
    code_review
    design_review
    incident_response
    presentation
    mentoring
    observation
    other
  ].freeze
  LINK_STATUSES = %w[active withdrawn].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: false, optional: true
  belongs_to :author, class_name: "Person", foreign_key: :author_id, inverse_of: false, optional: false
  belongs_to :withdrawn_by, class_name: "Person", foreign_key: :withdrawn_by_id, inverse_of: false, optional: true
  belongs_to :edited_by, class_name: "Person", foreign_key: :edited_by_id, inverse_of: false, optional: true
  has_many :evidence_links, foreign_key: :evidence_id, inverse_of: :evidence_item, dependent: :delete_all

  attribute :external_reference, ExternalReference.to_type, default: -> { ExternalReference.new }

  # Transient (non-persisted) count of this item's ACTIVE links, populated
  # by the matrix/controller queries so views can render an "also linked to
  # N other places" indicator and grey out "unlink from this capability" when the
  # item has only one link. Nil when not loaded — treat as a single link.
  attr_accessor :active_link_count

  # Transient map of `[capability_stable_id, level_ordinal] => valence` for
  # this item's ACTIVE links, populated alongside `active_link_count`. A map
  # (not a scalar) because valence is per-link and the same item object is
  # shared across every cell bucket it appears in. Nil when not loaded.
  attr_accessor :link_valences

  # Transient map of `[capability_stable_id, level_ordinal] =>
  # { count:, latest_body:, latest_author_name: }` for this item's
  # evidence-linkage discussion threads, populated alongside
  # `link_valences`. Per-cell, like valence — each linkage carries its
  # own independent thread. Nil when not loaded.
  attr_accessor :link_comment_stats

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :level_ordinal, numericality: { only_integer: true, greater_than_or_equal_to: 1 }, allow_nil: true
  validate :origin_cell_is_whole
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :feedback_direction, inclusion: { in: FEEDBACK_DIRECTIONS }, allow_nil: true
  validates :evidence_type, presence: true, inclusion: { in: EVIDENCE_TYPES }
  validates :custom_type_label, presence: true, if: -> { evidence_type == "other" }
  validates :custom_type_label, absence: true, unless: -> { evidence_type == "other" }
  validates :content, presence: true
  validates :link_status, presence: true, inclusion: { in: LINK_STATUSES }
  validates :external_reference, store_model: true
  validates :recorded_at, presence: true

  scope :active, -> { where(link_status: "active") }
  scope :withdrawn, -> { where(link_status: "withdrawn") }
  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :for_cycle, ->(cycle_id) { where(cycle_id: cycle_id) }
  scope :for_capability, ->(stable_id) { where(capability_stable_id: stable_id) }
  scope :at_level, ->(ordinal) { where(level_ordinal: ordinal) }
  # Active items with no ACTIVE link. Only an item recorded unplaced can be
  # here: the aggregate refuses to remove a placed item's last link, and a
  # framework migration that strips every link withdraws the item.
  scope :unplaced, -> { active.where.not(id: EvidenceLink.active.select(:evidence_id)) }

  # Classifies feedback from the provider to the recipient at recording time.
  # A manager source includes active rating delegates acting in manager
  # capacity. For peer-sourced feedback, the live relationship distinguishes
  # upward feedback from lateral feedback before the fact is persisted.
  #
  # @param source [String] derived evidence source
  # @param author [Person, nil] feedback provider
  # @param recipient [Person, nil] person receiving feedback
  # @return [String] one of FEEDBACK_DIRECTIONS
  def self.feedback_direction_for(source:, author:, recipient:)
    return "self" if source == "self"
    return "manager_to_report" if source == "manager"
    return "report_to_manager" if author&.managed_by?(recipient)

    "peer_to_peer"
  end

  # Whether this evidence has been withdrawn.
  #
  # @return [Boolean]
  def withdrawn?
    link_status == "withdrawn"
  end

  # Whether this item is still waiting to be placed on a capability × level.
  # Prefer the {.unplaced} scope over calling this across a list.
  #
  # @return [Boolean]
  def unplaced?
    !withdrawn? && !evidence_links.active.exists?
  end

  private

  def origin_cell_is_whole
    return if capability_stable_id.present? == level_ordinal.present?

    errors.add(:base, "capability_stable_id and level_ordinal must be set together")
  end
end
