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
# A seat still empty when its step ends stays empty into the steps after it
# ([#381](https://github.com/espaliahq/espalia/issues/381)). A later step
# takes away those days too, each priced and timed as the step the leaver
# left in. Each step counts only the days on its own dates, from the day after
# the latest earlier step ends, so no empty day counts twice.
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
  # @return [Array<TeamPlanning::Forecast::Row>] one per unit and cost centre with seats empty in the step
  def self.forecast(frame)
    days = frame.step.count
    vacancies = vacancies(frame, frame.step.begin, frame.step.end) + carried(frame)
    vacancies.group_by(&:first).sort_by { |key, _| key.map(&:to_s) }.map do |(unit_id, cost_centre), parts|
      frame.row(unit_id:, cost_centre:, headcount: -parts.sum(0r) { it[2] },
                cost: add(parts.map { |_, empty_days, _, average| average.cost.transform_values { -(it * empty_days / YEAR_DAYS) } }),
                capacity: add(parts.map { |_, empty_days, _, average| average.capacity.transform_values { -(it * empty_days / days) } }))
    end
  end

  # A seat stays empty past its step for up to the longest time to hire, and
  # only if some rate is above 0.
  #
  # @param values [Hash{String => Array<Hash>}] rule name => each value it could take
  # @return [Integer, nil]
  def self.reach(values)
    return unless values.fetch(rule_name, []).any? { yearly_rate(it).positive? }

    values.fetch(TeamPlanning::RuleKinds::TimeToHire.rule_name, []).map { TeamPlanning::RuleKinds::TimeToHire.days(it) }.max
  end

  # What earlier steps' leavers leave empty on this step's dates, from the day
  # after the latest of them ends. A unit this step no longer holds reads as
  # unplaced, as a seat outside every unit does.
  def self.carried(frame)
    from = frame.earlier.map { it.step.end + 1 }.max or return []
    live = frame.map.units.to_set(&:id)
    frame.earlier.flat_map { vacancies(it, [ from, frame.step.begin ].max, frame.step.end) }.map do |(unit_id, cost_centre), *rest|
      [ [ (unit_id if live.include?(unit_id)), cost_centre ], *rest ]
    end
  end
  private_class_method :carried

  # The seats a step's leavers leave empty between two dates, by unit and
  # cost centre: the empty FTE-days, the FTE still empty on the last date, and
  # the step's average filled FTE.
  #
  # @param source [TeamPlanning::Forecast::Frame] the step the leavers leave in
  # @param from [Date]
  # @param to [Date]
  # @return [Array<Array(Array(String, String), Rational, Rational, TeamPlanning::Forecast::Average)>]
  def self.vacancies(source, from, to)
    return [] if from > to

    length = source.step.count
    starts = (from - source.step.begin).to_i
    ends = (to + 1 - source.step.begin).to_i
    source.filled.group_by { [ it.unit_id, it.cost_centre ] }.filter_map do |(unit_id, cost_centre), places|
      rate = yearly_rate(source.rule_at(unit_id))
      next unless rate.positive?

      hire = TeamPlanning::RuleKinds::TimeToHire.days(source.map.rule(TeamPlanning::RuleKinds::TimeToHire.rule_name, unit_id:))
      leaving = rate * places.sum(0r, &:fte) / YEAR_DAYS
      empty_days = leaving * (emptied(ends, length, hire) - emptied(starts, length, hire))
      next if empty_days.zero?

      [ [ unit_id, cost_centre ], empty_days, leaving * ([ ends, length ].min - [ ends - hire, 0 ].max).clamp(0..), source.average(unit_id) ]
    end
  end

  # The empty FTE-days, per FTE leaving a day, from the step's start to a day
  # counted from it: every seat emptied by then, each empty for up to {TimeToHire}.
  #
  # @param day [Integer] days from the step's start
  # @param length [Integer] the step's days
  # @param hire [Integer] the time to hire
  # @return [Rational]
  def self.emptied(day, length, hire) = backlog(day, hire) - backlog(day - length, hire)

  def self.backlog(day, hire)
    return 0r unless day.positive?

    day <= hire ? Rational(day * day, 2) : Rational(hire * hire, 2) + (hire * (day - hire))
  end
  private_class_method :backlog

  def self.add(amounts) = amounts.flat_map(&:to_a).group_by(&:first).transform_values { |pairs| pairs.sum(0r, &:last) }.sort.to_h
  private_class_method :add
end
