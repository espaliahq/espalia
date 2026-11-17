# frozen_string_literal: true

# How many days a seat stays empty before someone starts in it. An assumption
# that varies by team, so it is a rule read at a unit like any other, never a
# setting of the plan ([#362](https://github.com/espaliahq/espalia/issues/362)).
#
# It also forecasts the hiring lag on an open seat the plan gives no target
# start ([#458](https://github.com/espaliahq/espalia/issues/458)): the seat is
# forecast to fill this many days after it opens ({TeamPlanning::SeatStart#forecast}).
# Cost takes away the seat's days in the step before then. Headcount, capacity
# and the run rate take the seat away only when it is forecast to fill after
# the step ends, as they read the step's last day. A seat with a target
# start, or on hold, is left alone, and 0 days forecasts nothing.
#
# @example
#   { "days" => "60" }
class TeamPlanning::RuleKinds::TimeToHire < TeamPlanning::ForecastKind
  DAYS = /\A\d{1,3}\z/
  MAX_DAYS = 730
  YEAR_DAYS = 365

  # @return [String]
  def self.rule_name = "time_to_hire"

  # @return [String]
  def self.description = "How many days a seat stays empty before someone starts in it: after a forecast leaver goes, or after an open seat with no target start opens"

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

  # @param frame [TeamPlanning::Forecast::Frame]
  # @return [Array<TeamPlanning::Forecast::Row>] one per unit and cost centre with a seat still being hired for
  def self.forecast(frame)
    live = frame.map.units.to_set(&:id)
    lags = TeamPlanning::SeatStart.openings(frame.map).filter_map do |position, fte, start|
      lag(frame, position, fte, start, live.include?(position.unit_id) ? position.unit_id : nil)
    end
    lags.group_by(&:first).sort_by { |key, _| key.map(&:to_s) }.map do |(unit_id, cost_centre), parts|
      frame.row(unit_id:, cost_centre:, headcount: parts.sum(0r) { it[1] }, cost: add(parts.map { it[2] }),
                capacity: add(parts.map { it[3] }), run_rate: add(parts.map { it[4] }))
    end
  end

  # One open part's lag in the step: its unit and cost centre, then what it
  # takes away from headcount, cost, capacity and the run rate.
  def self.lag(frame, position, fte, start, unit_id)
    held = start.held_in(frame.step) or return
    fills = start.forecast(time_to_hire: days(frame.map.rule(rule_name, unit_id:))) or return
    empty = ([ fills - 1, held.end ].min - held.begin).to_i + 1
    return unless empty.positive?

    priced = frame.open.fetch(position.id, TeamPlanning::Forecast::Open.new)
    unfilled = fills > frame.step.end
    [ [ unit_id, priced.cost_centre ], unfilled ? -fte : 0r,
      priced.cost.transform_values { -(it * fte * empty / YEAR_DAYS) },
      unfilled ? priced.capacity.transform_values { -(it * fte) } : {},
      unfilled ? priced.cost.transform_values { -(it * fte) } : {} ]
  end
  private_class_method :lag

  def self.add(amounts) = amounts.flat_map(&:to_a).group_by(&:first).transform_values { |pairs| pairs.sum(0r, &:last) }.sort.to_h
  private_class_method :add
end
