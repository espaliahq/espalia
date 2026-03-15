# frozen_string_literal: true

# Projection read model for role families within a published framework.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::RoleFamily < ApplicationRecord
  self.table_name = "framework_role_families"

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :framework, class_name: "FrameworkState::Framework",
             primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :role_families,
             optional: true
  has_many :roles, class_name: "FrameworkState::Role",
           primary_key: :role_family_id, foreign_key: :role_family_id, inverse_of: :role_family,
           dependent: :destroy

  validates :framework_id, presence: true
  validates :role_family_id, presence: true
  validates :name, presence: true
end
