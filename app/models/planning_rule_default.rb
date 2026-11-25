# frozen_string_literal: true

# A tenant's own default for one kind of Team Planning rule
# ({TeamPlanning::RuleKind}). Every plan starts from it, over the kind's
# built-in default, until the plan sets the rule itself.
class PlanningRuleDefault < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  self.ignored_columns += %w[updated_by_id]

  validates :rule, presence: true

  # @param rows [Enumerable<PlanningRuleDefault>] one tenant's, from the table or an archive's copy
  # @return [Hash{String => Hash}] each rule's value, the tenant's own over the built-in default
  def self.values_over_defaults(rows)
    defaults = TeamPlanning::RuleKinds.defaults
    defaults.merge(rows.select { defaults.key?(it.rule) }.to_h { [ it.rule, it.value ] })
  end
end
