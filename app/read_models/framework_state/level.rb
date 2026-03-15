# frozen_string_literal: true

# Projection read model for levels within a role.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::Level < ApplicationRecord
  self.table_name = "framework_levels"

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :role, class_name: "FrameworkState::Role",
             primary_key: :role_id, foreign_key: :role_id, inverse_of: :levels,
             optional: true

  validates :role_id, presence: true
  validates :level_id, presence: true
  validates :ordinal, presence: true
  validates :title, presence: true
  validates :code, presence: true
end
