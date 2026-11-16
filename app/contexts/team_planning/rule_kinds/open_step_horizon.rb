# frozen_string_literal: true

# How many whole months the figures run over for a step with no end date
# ([#404](https://github.com/espaliahq/espalia/issues/404)). The step itself
# has no end; only cost, budget, funding and the forecast stop here. A step
# has no unit, so the rule is plan-wide.
#
# @example
#   { "months" => "18" }
class TeamPlanning::RuleKinds::OpenStepHorizon < TeamPlanning::RuleKind
  MONTHS = /\A\d{1,2}\z/
  MAX_MONTHS = 36

  # @return [String]
  def self.rule_name = "open_step_horizon"

  # @return [String]
  def self.description = "How many whole months the figures run over for a step with no end date. Set for the whole plan, never a unit"

  # @return [Boolean]
  def self.plan_wide? = true

  # @return [Hash]
  def self.default = { "months" => "12" }

  # @return [Hash]
  def self.json_schema
    { type: "object",
      properties: { months: { type: "string", pattern: "^\\d{1,2}$", description: "Whole months from 1 to #{MAX_MONTHS}, such as 18" } },
      required: %w[months], additionalProperties: false }
  end

  # @param value [Hash] with string keys
  # @return [Hash] the months as stored
  # @raise [TeamPlanning::Error] for another key, or months that aren't whole and in range
  def self.check(value)
    extra = value.keys - %w[months]
    raise TeamPlanning::Error, "An open_step_horizon rule takes only months, not #{extra.join(", ")}" if extra.any?

    months = value["months"].to_s.strip
    unless months.match?(MONTHS) && months.to_i.between?(1, MAX_MONTHS)
      raise TeamPlanning::Error, "months must be whole months from 1 to #{MAX_MONTHS}, such as 18"
    end

    { "months" => months.to_i.to_s }
  end

  # @param value [Hash] as {.check} stored it
  # @return [Integer]
  def self.months(value) = value.fetch("months").to_i
end
