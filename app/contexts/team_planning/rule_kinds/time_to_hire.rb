# frozen_string_literal: true

# How many days a seat stays empty before its backfill starts. An assumption
# that varies by team, so it is a rule read at a unit like any other, never a
# setting of the plan ([#362](https://github.com/espaliahq/espalia/issues/362)).
#
# @example
#   { "days" => "60" }
class TeamPlanning::RuleKinds::TimeToHire < TeamPlanning::RuleKind
  DAYS = /\A\d{1,3}\z/
  MAX_DAYS = 730

  # @return [String]
  def self.rule_name = "time_to_hire"

  # @return [String]
  def self.description = "How many days a seat stays empty before its backfill starts, such as after a forecast leaver goes"

  # @return [Hash]
  def self.default = { "days" => "90" }

  # @return [Hash]
  def self.json_schema
    { type: "object",
      properties: { days: { type: "string", pattern: "^\\d{1,3}$", description: "Whole days from 0 to #{MAX_DAYS}, such as 60" } },
      required: %w[days], additionalProperties: false }
  end

  # @param value [Hash] with string keys
  # @return [Hash] the days as stored
  # @raise [TeamPlanning::Error] for another key, or days that aren't whole and in range
  def self.check(value)
    extra = value.keys - %w[days]
    raise TeamPlanning::Error, "A time_to_hire rule takes only days, not #{extra.join(", ")}" if extra.any?

    days = value["days"].to_s.strip
    raise TeamPlanning::Error, "days must be whole days from 0 to #{MAX_DAYS}, such as 60" unless days.match?(DAYS) && days.to_i <= MAX_DAYS

    { "days" => days.to_i.to_s }
  end

  # @param value [Hash] as {.check} stored it
  # @return [Integer]
  def self.days(value) = value.fetch("days").to_i
end
