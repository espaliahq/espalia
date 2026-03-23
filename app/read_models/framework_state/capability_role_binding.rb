# frozen_string_literal: true

# Projection read model for capability-role bindings.
#
# Bindings tie a capability to a role with a weight and optional scoring overrides.
#
# == deficit_threshold
# Maximum acceptable uncapped weighted deficit for this capability at the rated
# level before it blocks mastery / promotion verdicts and caps the category pool:
#
#   nil  — governed by category or framework deficit_threshold
#   0    — no deficit allowed (equivalent to former mandatory?: true)
#   N    — deficit capped at N for pool; any deficit >= N blocks verdicts
#
# == overperformance_cap
# Number of levels above the person's assigned level that still contribute to
# the score. Ordinals beyond person_level + cap contribute 0.
#
#   nil  — governed by category or framework overperformance_cap
#   1    — only the immediate next level earns positive credit (framework default)
#   N    — up to N levels above current earn credit
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::CapabilityRoleBinding < ApplicationRecord
  self.table_name = "framework_capability_role_bindings"

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
  validates :deficit_threshold, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :overperformance_cap, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
