# frozen_string_literal: true

# Projection read model for pending and resolved suggested edits, creates,
# and deletes.
#
# Tracks the lifecycle of inline content suggestions on framework entities.
# A suggestion moves through: pending → approved | rejected | withdrawn.
#
# Three kinds:
# - "edit"   — propose a new value for a field on an existing entity
# - "create" — propose adding a new entity (uses proposed_attributes + parent_id)
# - "delete" — propose removing/archiving an existing entity
#
# When approved, the matching command is dispatched on the aggregate, which
# in turn updates the entity's own read model (e.g. FrameworkState::RoleIllustration).
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::SuggestedEdit < ApplicationRecord
  self.table_name = "framework_suggested_edits"

  STATUSES = %w[pending approved rejected withdrawn].freeze
  KINDS = %w[edit create delete].freeze

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

  # Edit suggestions need an existing target and a field/value diff.
  validates :target_entity_id, presence: true, if: -> { kind == "edit" || kind == "delete" }
  validates :field, presence: true, if: -> { kind == "edit" }
  validates :suggested_value, presence: true, if: -> { kind == "edit" }

  scope :pending, -> { where(status: "pending") }
  scope :edits, -> { where(kind: "edit") }
  scope :creates, -> { where(kind: "create") }
  scope :deletes, -> { where(kind: "delete") }
  scope :for_entity, ->(type, id) { where(target_entity_type: type, target_entity_id: id) }
end
