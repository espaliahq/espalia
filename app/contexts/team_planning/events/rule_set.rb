# frozen_string_literal: true

# A scenario sets one rule ({TeamPlanning::RuleKind}) for the whole plan or
# for one unit and the units below it. The subject is the plan's id for the
# whole plan, or the unit's id.
#
# Every rule is its own facet, so two rules on one subject both land, and a
# unit's rule never competes with the plan-wide one.
#
# @!attribute [r] data
#   @return [Hash] event data, as {TeamPlanning::Events::Change} holds, and
#   @option data [String] :rule the kind's {TeamPlanning::RuleKind.rule_name}
#   @option data [Hash] :value as the kind checked it
class TeamPlanning::Events::RuleSet < TeamPlanning::Events::Change
  # @return [String]
  def self.facet = "rule"

  # @param end_state [Hash] `{ rule:, value: }`
  # @return [Hash]
  # @raise [TeamPlanning::Error] for another field, an unknown rule or a refused value
  def self.end_state(end_state)
    extra = end_state.keys.map(&:to_sym) - %i[rule value]
    raise TeamPlanning::Error, "A rule takes only rule and value, not #{extra.join(", ")}" if extra.any?

    rule = end_state[:rule].to_s
    { rule:, value: TeamPlanning::RuleKinds.check(rule, end_state[:value]) }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data) = map.with(rules: map.rules.with_rule(data[:subject_id], data[:rule], data[:value]))

  # @return [Array(String, String)] the subject and this rule, so each rule wins on its own
  def key = [ data[:subject_id], "#{self.class.facet}:#{data[:rule]}" ]
end
