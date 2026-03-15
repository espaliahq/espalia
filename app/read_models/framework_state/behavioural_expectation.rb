# frozen_string_literal: true

# Projection read model for behavioural expectations.
#
# One per Capability × Level ordinal. This is the canonical definition
# people are rated against. Role-specific context comes from
# {FrameworkState::RoleIllustration}.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::BehaviouralExpectation < ApplicationRecord
  self.table_name = "framework_behavioural_expectations"

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :capability, class_name: "FrameworkState::Capability",
             primary_key: :capability_id, foreign_key: :capability_id, inverse_of: :expectations,
             optional: true
  has_many :illustrations, class_name: "FrameworkState::RoleIllustration",
           primary_key: :expectation_id, foreign_key: :expectation_id, inverse_of: :expectation,
           dependent: :destroy

  validates :expectation_id, presence: true
  validates :stable_id, presence: true
  validates :capability_id, presence: true
  validates :level_ordinal, presence: true
  validates :description, presence: true
end
