# frozen_string_literal: true

# Projection read model for role-specific illustrations.
#
# Illustrations are clarifying examples for a behavioural expectation
# in the context of a specific role. They are NOT separately rated.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::RoleIllustration < ApplicationRecord
  self.table_name = "framework_role_illustrations"

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :expectation, class_name: "FrameworkState::BehaviouralExpectation",
             primary_key: :expectation_id, foreign_key: :expectation_id, inverse_of: :illustrations,
             optional: true
  belongs_to :role, class_name: "FrameworkState::Role",
             primary_key: :role_id, foreign_key: :role_id, inverse_of: :illustrations,
             optional: true

  validates :illustration_id, presence: true
  validates :stable_id, presence: true
  validates :expectation_id, presence: true
  validates :role_id, presence: true
  validates :ordinal, presence: true
  validates :description, presence: true
end
