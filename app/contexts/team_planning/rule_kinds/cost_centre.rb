# frozen_string_literal: true

# Which cost centre a position draws on when it names none and nobody fills
# it: an ordered list of a matcher and a label, where the first match wins. A
# matcher names a unit (and so its subtree), a role, a role family, or a unit
# with a role or role family. The rules never move a person's own cost.
#
# @example
#   { "rules" => [ { "unit_id" => platform_id, "role_family_id" => engineering_id, "cost_centre" => "Platform Eng" },
#                  { "unit_id" => platform_id, "cost_centre" => "Platform" } ] }
class TeamPlanning::RuleKinds::CostCentre < TeamPlanning::RuleKind
  MATCHERS = %w[unit_id role_id role_family_id].freeze
  KEYS = (MATCHERS + %w[cost_centre]).freeze
  MAX_RULES = 200

  # @return [String]
  def self.rule_name = "cost_centre"

  # @return [String]
  def self.description = "Which cost centre an open position draws on, as an ordered list of a matcher and a label; the first match wins"

  # @return [Hash]
  def self.default = { "rules" => [] }

  # @return [Hash]
  def self.json_schema
    rule = { type: "object", required: [ "cost_centre" ], additionalProperties: false,
             properties: { unit_id: { type: "string", description: "A unit, matching it and every unit below it" },
                           role_id: { type: "string" }, role_family_id: { type: "string", description: "Not with role_id" },
                           cost_centre: { type: "string", maxLength: TeamPlanning::Events::PositionSet::COST_CENTRE_LENGTH } } }
    { type: "object", properties: { rules: { type: "array", items: rule, maxItems: MAX_RULES } } }
  end

  # @param value [Hash] with string keys
  # @return [Hash] each id downcased, each label squished
  # @raise [TeamPlanning::Error] for another key, a rule without a matcher or label, or one naming a role and a family
  def self.check(value)
    extra = value.keys - %w[rules]
    raise TeamPlanning::Error, "A cost_centre rule takes only rules, not #{extra.join(", ")}" if extra.any?

    rules = value.fetch("rules", [])
    raise TeamPlanning::Error, "A cost_centre rule's rules must be a list" unless rules.is_a?(Array)
    raise TeamPlanning::Error, "A cost_centre rule holds at most #{MAX_RULES} rules" if rules.size > MAX_RULES

    { "rules" => rules.map { rule!(it) } }
  end

  # @param value [Hash] as {.check} stored it
  # @param unit_ids [Array<String>] the position's unit and every unit above it
  # @param role_id [String]
  # @param family_id [String, nil]
  # @return [Array(Integer, Hash), nil] the first matching rule's index and the rule, nil when none matches
  def self.match(value, unit_ids:, role_id:, family_id:)
    value["rules"].each_with_index do |rule, index|
      next if rule["unit_id"] && !unit_ids.include?(rule["unit_id"])
      next if rule["role_id"] && rule["role_id"] != role_id
      next if rule["role_family_id"] && rule["role_family_id"] != family_id

      return [ index, rule ]
    end
    nil
  end

  def self.rule!(rule)
    raise TeamPlanning::Error, "Each cost centre rule must be an object" unless rule.is_a?(Hash)

    extra = rule.keys - KEYS
    raise TeamPlanning::Error, "A cost centre rule takes only #{KEYS.join(", ")}, not #{extra.join(", ")}" if extra.any?

    ids = MATCHERS.to_h { [ it, rule[it].to_s.strip.downcase.presence ] }.compact
    raise TeamPlanning::Error, "Each cost centre rule names a unit, a role or a role family" if ids.empty?
    raise TeamPlanning::Error, "A cost centre rule names a role or a role family, not both" if ids.key?("role_id") && ids.key?("role_family_id")

    label = rule["cost_centre"].to_s.squish
    raise TeamPlanning::Error, "Each cost centre rule names a cost centre" if label.empty?

    length = TeamPlanning::Events::PositionSet::COST_CENTRE_LENGTH
    raise TeamPlanning::Error, "A cost centre is at most #{length} characters" if label.length > length

    { **ids, "cost_centre" => label }
  end

  private_class_method :rule!
end
