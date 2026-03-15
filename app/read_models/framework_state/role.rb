# frozen_string_literal: true

# Projection read model for roles within a published framework.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::Role < ApplicationRecord
  self.table_name = "framework_roles"

  TRACKS = %w[ic management].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :role_family, class_name: "FrameworkState::RoleFamily",
             primary_key: :role_family_id, foreign_key: :role_family_id, inverse_of: :roles,
             optional: true
  has_many :levels, class_name: "FrameworkState::Level",
           primary_key: :role_id, foreign_key: :role_id, inverse_of: :role,
           dependent: :destroy
  has_many :bindings, class_name: "FrameworkState::CapabilityRoleBinding",
           primary_key: :role_id, foreign_key: :role_id, inverse_of: :role,
           dependent: :destroy
  has_many :illustrations, class_name: "FrameworkState::RoleIllustration",
           primary_key: :role_id, foreign_key: :role_id, inverse_of: :role,
           dependent: :destroy

  validates :role_family_id, presence: true
  validates :role_id, presence: true
  validates :name, presence: true
  validates :code, presence: true
  validates :track, presence: true, inclusion: { in: TRACKS }
end
