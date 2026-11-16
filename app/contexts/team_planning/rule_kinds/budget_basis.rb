# frozen_string_literal: true

# Whether a scenario's budget includes on-costs or is base pay only
# ([#369](https://github.com/espaliahq/espalia/issues/369)). Funded is measured
# on the same basis, so the budget's four numbers compare like with like. A
# budget line has no unit, so the rule is plan-wide.
#
# @example
#   { "basis" => "base_only" }
class TeamPlanning::RuleKinds::BudgetBasis < TeamPlanning::RuleKind
  BASES = %w[inclusive base_only].freeze

  # @return [String]
  def self.rule_name = "budget_basis"

  # @return [String]
  def self.description = "Whether the budget includes on-costs (inclusive) or is base pay only (base_only). Set for the whole plan, never a unit"

  # @return [Boolean]
  def self.plan_wide? = true

  # @return [Hash]
  def self.default = { "basis" => "inclusive" }

  # @return [Hash]
  def self.json_schema
    { type: "object", properties: { basis: { type: "string", enum: BASES, description: "inclusive: base pay plus on-cost. base_only: base pay alone" } },
      required: %w[basis], additionalProperties: false }
  end

  # @param value [Hash] with string keys
  # @return [Hash] the basis as stored
  # @raise [TeamPlanning::Error] for another key, or a basis that isn't one of {BASES}
  def self.check(value)
    extra = value.keys - %w[basis]
    raise TeamPlanning::Error, "A budget_basis rule takes only basis, not #{extra.join(", ")}" if extra.any?
    raise TeamPlanning::Error, "basis must be inclusive or base_only" unless BASES.include?(value["basis"])

    { "basis" => value["basis"] }
  end

  # @param value [Hash] as {.check} stored it
  # @return [Boolean] whether the budget counts on-costs
  def self.inclusive?(value) = value.fetch("basis") == "inclusive"
end
