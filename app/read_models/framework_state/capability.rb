# frozen_string_literal: true

# Projection read model for capabilities within a published framework.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::Capability < ApplicationRecord
  self.table_name = "framework_capabilities"

  STATUSES = %w[active archived].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :category, class_name: "FrameworkState::CapabilityCategory",
             primary_key: :category_id, foreign_key: :category_id, inverse_of: :capabilities,
             optional: true
  has_many :bindings, class_name: "FrameworkState::CapabilityRoleBinding",
           primary_key: :capability_id, foreign_key: :capability_id, inverse_of: :capability,
           dependent: :destroy
  has_many :expectations, class_name: "FrameworkState::BehaviouralExpectation",
           primary_key: :capability_id, foreign_key: :capability_id, inverse_of: :capability,
           dependent: :destroy

  validates :category_id, presence: true
  validates :capability_id, presence: true
  validates :stable_id, presence: true
  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :archived, -> { where(status: "archived") }
end
