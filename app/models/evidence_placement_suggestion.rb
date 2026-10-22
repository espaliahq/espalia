# frozen_string_literal: true

# A cell (capability × level) and valence the model proposes for a piece of
# feedback, until a person decides. Not event-sourced: a pending suggestion
# is regenerable machine output and worthless once decided. The decision is
# what the stream records — an accepted suggestion becomes an
# EvidenceLinkAdded or EvidenceLinkRevalenced carrying `via_suggestion_id`.
#
# One row per evidence × cell. Regenerating supersedes the pending set and
# reuses a superseded row when the model proposes the same cell again; a cell
# someone dismissed is never proposed again.
class EvidencePlacementSuggestion < ApplicationRecord
  STATUSES = %w[pending accepted edited dismissed superseded].freeze
  DECIDED_STATUSES = %w[accepted edited dismissed].freeze
  # A rationale quotes the feedback in one sentence; anything longer is the
  # model rambling, and the hub row has room for one line. A decision model
  # (Jev) writes none, so it may be blank.
  RATIONALE_MAX_LENGTH = 400

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :evidence_item, foreign_key: :evidence_id, inverse_of: false, optional: true
  belongs_to :decided_by, class_name: "Person", inverse_of: false, optional: true

  validates :evidence_id, :person_id, :framework_id, :capability_stable_id, presence: true
  validates :level_ordinal, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :valence, inclusion: { in: EvidenceLink::VALENCES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :rationale, length: { maximum: RATIONALE_MAX_LENGTH }
  validates :status, inclusion: { in: STATUSES }
  validates :provider, inclusion: { in: AiModelConfig::PROVIDERS }
  validates :model, :prompt_version, :generated_at, presence: true

  scope :pending, -> { where(status: "pending") }
  scope :for_evidence, ->(evidence_id) { where(evidence_id: evidence_id) }
  scope :most_confident_first, -> { order(confidence: :desc, generated_at: :asc) }

  # @return [Boolean]
  def pending? = status == "pending"

  # @return [Array(String, Integer)] the cell as the evidence diff keys it
  def cell = [ capability_stable_id, level_ordinal ]

  # Records a person's decision. Callers authorise first.
  #
  # @param status [String] one of DECIDED_STATUSES
  # @param by [Person]
  # @param reason [String, nil] why it was dismissed
  # @return [void]
  def decide!(status:, by:, reason: nil)
    raise ArgumentError, "not a decision: #{status}" unless DECIDED_STATUSES.include?(status)

    update!(status: status, decided_by_id: by.id, decided_at: Time.current, dismiss_reason: reason.presence)
  end

  # @param evidence_ids [Array<String>]
  # @return [Hash{String => Array<EvidencePlacementSuggestion>}] pending rows
  #   per item, most confident first
  def self.pending_by_evidence(evidence_ids)
    return {} if evidence_ids.empty?

    pending.where(evidence_id: evidence_ids).most_confident_first.group_by(&:evidence_id)
  end
end
