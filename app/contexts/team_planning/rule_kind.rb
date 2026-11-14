# frozen_string_literal: true

# One kind of rule a plan follows, such as an on-cost model or a guardrail.
# Each kind names itself, gives its built-in default and checks a value
# before it is stored. A value is always an object, held with string keys.
#
# A rule's value may be close to pay, so a refusal from {.check} names what is
# wrong and never repeats the value.
#
# @example
#   class TeamPlanning::RuleKinds::OnCost < TeamPlanning::RuleKind
#     def self.rule_name = "on_cost"
#     def self.description = "What a position costs on top of its pay"
#     def self.default = { "model" => "flat", "rate" => "0" }
#   end
class TeamPlanning::RuleKind
  # @return [String] the name a rule is set and read by, in snake_case
  def self.rule_name = raise(NotImplementedError, "#{name} must name its rule")

  # @return [String] what the rule decides, for the tools that list rules
  def self.description = raise(NotImplementedError, "#{name} must describe its rule")

  # @return [Hash] the value until the tenant or a plan sets one
  def self.default = raise(NotImplementedError, "#{name} must give its default")

  # @return [Hash] a JSON Schema fragment for the value, so a client can see its keys
  def self.json_schema = { type: "object" }

  # @param value [Hash] with string keys
  # @return [Hash] the value as stored
  # @raise [TeamPlanning::Error] naming what is wrong, never the value
  def self.check(value) = value

  # A shreddable value is stored encrypted under the plan's key, so it can be
  # shredded. The shredding comes with Team Planning 2.2 (#213); until then
  # {TeamPlanning::RuleKinds} refuses a kind that declares one.
  #
  # @return [Boolean]
  def self.shreddable? = false
end
