# frozen_string_literal: true

# Projection read model for capability categories within a published framework.
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
end
