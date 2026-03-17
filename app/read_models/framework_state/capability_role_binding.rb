# frozen_string_literal: true

# Projection read model for capability-role bindings.
#
# Bindings tie a capability to a role with a weight and optional individual
# tolerance. The individual_tolerance caps how much this capability's deficit
# can contribute to its category's tolerance pool:
#
#   nil  — governed by category_tolerance only
#   0    — mandatory: no deficit allowed, no category compensation
#   N    — deficit capped at N before entering the category pool
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
  validates :individual_tolerance, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Returns true if this capability has zero tolerance — no deficit allowed.
  #
  # @return [Boolean]
  def mandatory?
    individual_tolerance&.zero?
  end
end
