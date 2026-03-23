# frozen_string_literal: true

# Projection read model for published framework state.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::Framework < ApplicationRecord
  self.table_name = "framework_states"

  acts_as_tenant :tenant
  has_prefix_id :frm

  belongs_to :tenant
  has_many :role_families, class_name: "FrameworkState::RoleFamily",
           primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :framework,
           dependent: :destroy
  has_many :capability_categories, class_name: "FrameworkState::CapabilityCategory",
           primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :framework,
           dependent: :destroy

  validates :framework_id, presence: true
  validates :name, presence: true
  validates :overperformance_cap, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :deficit_threshold, numericality: { greater_than_or_equal_to: 0 }
end
