# frozen_string_literal: true

# A tenant's own default for one kind of Team Planning rule
# ({TeamPlanning::RuleKind}). Every plan starts from it, over the kind's
# built-in default, until the plan sets the rule itself.
class PlanningRuleDefault < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :updated_by, class_name: "User", optional: true

  validates :rule, presence: true, uniqueness: { scope: :tenant_id }

  # @param tenant_id [String]
  # @return [Hash{String => Hash}] each rule's value, the tenant's own over the built-in default
  def self.values_for(tenant_id)
    defaults = TeamPlanning::RuleKinds.defaults
    defaults.merge(where(tenant_id:, rule: defaults.keys).pluck(:rule, :value).to_h)
  end
end
