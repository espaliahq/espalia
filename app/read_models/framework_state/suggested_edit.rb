# frozen_string_literal: true

# Projection read model for pending and resolved suggested edits.
#
# Tracks the lifecycle of inline content suggestions on framework entities.
# A suggestion moves through: pending → approved | rejected | withdrawn.
#
# When approved, the actual content change is applied to the entity's own
# read model (e.g. FrameworkState::RoleIllustration).
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::SuggestedEdit < ApplicationRecord
  self.table_name = "framework_suggested_edits"

  STATUSES = %w[pending approved rejected withdrawn].freeze

  # Pundit policy lookup: use FrameworkSuggestionPolicy
  # (not FrameworkState::SuggestedEditPolicy)
  def self.policy_class
    FrameworkSuggestionPolicy
  end

  acts_as_tenant :tenant

  belongs_to :tenant

  validates :framework_id, presence: true
  validates :suggestion_id, presence: true
  validates :target_entity_type, presence: true
  validates :target_entity_id, presence: true
  validates :field, presence: true
  validates :suggested_value, presence: true
  validates :author_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :for_entity, ->(type, id) { where(target_entity_type: type, target_entity_id: id) }
end
