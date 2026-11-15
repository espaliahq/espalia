# frozen_string_literal: true

# The share of a unit's filled seats expected to leave in a year
# ([#362](https://github.com/espaliahq/espalia/issues/362)). Each leaver's seat
# stays empty for the unit's {TimeToHire}, then its backfill starts, so the
# forecast takes away the cost and capacity of the empty days.
#
# The rate applies to people in filled seats only: never to an open position
# or a planned hire, nor to anyone a planned change covers, such as a leaver
# with a `DepartureSet`. People who have left are on no map.
#
# Leavers go evenly through the step. With a rate r, F filled FTE, a step of L
# days and a time to hire of T, the empty FTE-days are r × F / 365 times
# T × L − T² / 2, or L² / 2 when T is at least L, as a seat emptied late in the
# step is still empty at its end. Cost takes away the unit's average yearly
# cost of a filled FTE for those days over a 365-day year; capacity takes away
# its average capacity of a filled FTE, over the step's days; headcount is the
# FTE still empty when the step ends, r × F × min(T, L) / 365. Every figure is
# an exact fraction, never rounded to people, and names nobody.
#
# @example
#   { "yearly_rate" => "0.12" }
class TeamPlanning::RuleKinds::Attrition < TeamPlanning::ForecastKind
  RATE = /\A(0(\.\d{1,4})?|1(\.0{1,4})?)\z/
  YEAR_DAYS = 365

  # @return [String]
  def self.rule_name = "attrition"

  # @return [String]
  def self.description = "The share of a unit's filled seats expected to leave in a year, each seat empty for the unit's time to hire"

  # @return [Hash]
  def self.default = { "yearly_rate" => "0" }

  # @return [Hash]
  def self.json_schema
    { type: "object",
      properties: { yearly_rate: { type: "string", pattern: "^(0(\\.\\d{1,4})?|1(\\.0{1,4})?)$",
                                   description: "A share of a year from 0 to 1, such as 0.12 for 12%" } },
      required: %w[yearly_rate], additionalProperties: false }
  end

  # @param value [Hash] with string keys
  # @return [Hash] the rate as stored
  # @raise [TeamPlanning::Error] for another key, or a rate outside 0 to 1
  def self.check(value)
    extra = value.keys - %w[yearly_rate]
    raise TeamPlanning::Error, "An attrition rule takes only yearly_rate, not #{extra.join(", ")}" if extra.any?

    rate = value["yearly_rate"].to_s.strip
    raise TeamPlanning::Error, "yearly_rate must be a share of a year from 0 to 1, such as 0.12" unless rate.match?(RATE)

    { "yearly_rate" => rate }
  end

  # @param value [Hash] as {.check} stored it
  # @return [Rational]
  def self.yearly_rate(value) = value.fetch("yearly_rate").to_r

  # @param frame [TeamPlanning::Forecast::Frame]
  # @return [Array<TeamPlanning::Forecast::Row>] one per unit and cost centre with filled FTE and a rate above 0
  def self.forecast(frame)
    days = frame.step.count
    frame.filled.group_by { [ it.unit_id, it.cost_centre ] }.sort_by { |key, _| key.map(&:to_s) }.filter_map do |(unit_id, cost_centre), places|
      rate = yearly_rate(frame.rule_at(unit_id))
      next unless rate.positive?

      hire = TeamPlanning::RuleKinds::TimeToHire.days(frame.map.rule(TeamPlanning::RuleKinds::TimeToHire.rule_name, unit_id:))
      fte = places.sum(0r, &:fte)
      empty_days = rate * fte / YEAR_DAYS * (hire < days ? (hire * days) - Rational(hire * hire, 2) : Rational(days * days, 2))
      average = frame.average(unit_id)
      frame.row(unit_id:, cost_centre:, headcount: -(rate * fte * [ hire, days ].min / YEAR_DAYS),
                cost: average.cost.transform_values { -(it * empty_days / YEAR_DAYS) },
                capacity: average.capacity.transform_values { -(it * empty_days / days) })
    end
  end
end
