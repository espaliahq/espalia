# frozen_string_literal: true

# Projection read model for capability categories within a published framework.
#
# category_tolerance controls how much total weighted deficit is acceptable
# across all capabilities in this category for a given assessment:
#
#   nil  — uncapped: category is informational for scoring only, no pass/fail gate
#   0    — group must balance: net weighted deficit must be >= 0
#   N    — group absorbs up to N weighted points of deficit
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
  has_many :capabilities, class_name: "FrameworkState::Capability",
           primary_key: :category_id, foreign_key: :category_id, inverse_of: :category,
           dependent: :destroy

  validates :framework_id, presence: true
  validates :category_id, presence: true
  validates :name, presence: true
  validates :category_tolerance, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
