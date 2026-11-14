# frozen_string_literal: true

# How many hours a full-time seat works in a year, which turns an hourly pay
# band into a yearly cost. Read at a seat's unit, like any rule.
#
# The default is 40 hours a week for 52 weeks.
#
# @example
#   { "hours_per_year" => "1950" }
class TeamPlanning::RuleKinds::WorkingHours < TeamPlanning::RuleKind
  HOURS = /\A\d{1,4}(\.\d{1,2})?\z/
  MAX_HOURS = 8784

  # @return [String]
  def self.rule_name = "working_hours"

  # @return [String]
  def self.description = "How many hours a full-time seat works in a year, which turns an hourly pay band into a yearly cost"

  # @return [Hash]
  def self.default = { "hours_per_year" => "2080" }

  # @return [Hash]
  def self.json_schema
    { type: "object",
      properties: { hours_per_year: { type: "string", pattern: "^\\d{1,4}(\\.\\d{1,2})?$",
                                      description: "Hours in a full-time year, more than 0 and at most #{MAX_HOURS}, such as 1950" } },
      required: %w[hours_per_year], additionalProperties: false }
  end

  # @param value [Hash] with string keys
  # @return [Hash] the hours as stored
  # @raise [TeamPlanning::Error] for another key, or hours that aren't a year's worth
  def self.check(value)
    extra = value.keys - %w[hours_per_year]
    raise TeamPlanning::Error, "A working_hours rule takes only hours_per_year, not #{extra.join(", ")}" if extra.any?

    hours = value["hours_per_year"].to_s.strip
    unless hours.match?(HOURS) && hours.to_r.positive? && hours.to_r <= MAX_HOURS
      raise TeamPlanning::Error, "hours_per_year must be the hours in a full-time year, such as 1950"
    end

    { "hours_per_year" => hours }
  end

  # @param value [Hash] as {.check} stored it
  # @return [Rational]
  def self.hours_per_year(value) = value.fetch("hours_per_year").to_r
end
