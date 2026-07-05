# frozen_string_literal: true

# Projection read model for capability categories within a published framework.
#
# deficit_threshold serves dual purpose at the category level:
#
#   1. Per-capability fallback: capabilities without their own deficit_threshold
#      inherit from the category (then framework if category is nil).
#   2. Category pool tolerance: maximum acceptable net weighted deficit across
#      all capabilities in this category.
#
#   nil  — inherits from framework (default 1.0)
#   0    — group must balance: no net deficit allowed
#   N    — group absorbs up to N weighted points of net deficit
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::CapabilityCategory < ApplicationRecord
  self.table_name = "framework_capability_categories"

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :framework, class_name: "FrameworkState::Framework",
             primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :capability_categories,
             optional: true
  # Display-canonical order: reorder ordinals first (PG sorts ASC nulls-last),
  # then id (uuidv7 ≈ insertion) so never-reordered capabilities keep their
  # creation order and ones added after a reorder land at the end.
  has_many :capabilities, -> { order(:ordinal, :id) },
           class_name: "FrameworkState::Capability",
           primary_key: :category_id, foreign_key: :category_id, inverse_of: :category,
           dependent: :destroy

  validates :framework_id, presence: true
  validates :category_id, presence: true
  validates :name, presence: true
  validates :deficit_threshold, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :overperformance_cap, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
