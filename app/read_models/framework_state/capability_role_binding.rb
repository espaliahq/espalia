# frozen_string_literal: true

# Projection read model for capability-role bindings.
#
# Bindings tie a capability to a role with weight and requirement type.
# This is the scoping mechanism — not category-level scope.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::CapabilityRoleBinding < ApplicationRecord
  self.table_name = "framework_capability_role_bindings"

  REQUIREMENT_TYPES = %w[must_have flexible].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :capability, class_name: "FrameworkState::Capability",
             primary_key: :capability_id, foreign_key: :capability_id, inverse_of: :bindings,
             optional: true
  belongs_to :role, class_name: "FrameworkState::Role",
             primary_key: :role_id, foreign_key: :role_id, inverse_of: :bindings,
             optional: true

  validates :binding_id, presence: true
  validates :capability_id, presence: true
  validates :role_id, presence: true
  validates :weight, presence: true
  validates :requirement_type, presence: true, inclusion: { in: REQUIREMENT_TYPES }
end
