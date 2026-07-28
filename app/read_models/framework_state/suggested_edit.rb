# frozen_string_literal: true

# Projection read model for pending and resolved suggested edits, creates,
# and deletes.
#
# Tracks the lifecycle of inline content suggestions on framework entities.
# A suggestion moves through: pending → approved | rejected | withdrawn.
#
# Four kinds:
# - "edit"          — propose a new value for a field on an existing entity
# - "create"        — propose adding a new entity (uses proposed_attributes + parent_id)
# - "delete"        — propose removing/archiving an existing entity
# - "clarification" — a NON-PROPOSAL kind: anchors a lifecycled discussion on
#                     an expectation (or an empty capability × level cell —
#                     level in proposed_attributes) without proposing a value.
#                     Lifecycle: pending → resolved (with a note, reviewer_comment,
#                     optionally resulting_suggestion_id) | withdrawn — never
#                     approved/rejected.
#
# When a proposal kind is approved, the matching command is dispatched on the
# aggregate, which in turn updates the entity's own read model
# (e.g. FrameworkState::RoleIllustration).
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::SuggestedEdit < ApplicationRecord
  self.table_name = "framework_suggested_edits"

  STATUSES = %w[pending approved rejected withdrawn resolved].freeze
  KINDS = %w[edit create delete clarification].freeze
  # The kinds that propose a concrete change applied on approval —
  # clarifications are deliberately outside this set.
  PROPOSAL_KINDS = %w[edit create delete].freeze

  # Pundit policy lookup: use FrameworkSuggestionPolicy
  # (not FrameworkState::SuggestedEditPolicy)
  def self.policy_class
    FrameworkSuggestionPolicy
  end

  acts_as_tenant :tenant

  belongs_to :tenant

  validates :framework_id, presence: true
  validates :suggestion_id, presence: true
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :target_entity_type, presence: true
  validates :author_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  # Edit suggestions need an existing target and a field/value diff; a
  # clarification anchors an existing target but proposes nothing (nil
  # field/suggested_value — the presence rules were always proposal-kind rules).
  validates :target_entity_id, presence: true, if: -> { kind.in?(%w[edit delete clarification]) }
  validates :field, presence: true, if: -> { kind == "edit" }
  validates :suggested_value, presence: true, if: -> { kind == "edit" }

  scope :pending, -> { where(status: "pending") }
  scope :edits, -> { where(kind: "edit") }
  scope :creates, -> { where(kind: "create") }
  scope :deletes, -> { where(kind: "delete") }
  scope :clarifications, -> { where(kind: "clarification") }
  scope :proposals, -> { where(kind: PROPOSAL_KINDS) }
  scope :for_entity, ->(type, id) { where(target_entity_type: type, target_entity_id: id) }

  # @return [Boolean] whether this suggestion proposes a concrete change
  def proposal?
    PROPOSAL_KINDS.include?(kind)
  end

  # @return [Boolean]
  def clarification?
    kind == "clarification"
  end
end
