# frozen_string_literal: true

# When an open seat starts: the one rule cost, capacity, the forecast and the
# headcount walk share ([#458](https://github.com/espaliahq/espalia/issues/458)).
#
# A seat starts on its position's target start, never before the day it
# opens, and not at all while recruiting is on hold. An undated seat starts
# the day it opens, as it always has in the plan's own figures; the forecast
# then holds it empty for the unit's time to hire.
#
# Capacity is a step's end state, so a seat has started in a step when its
# start falls on or before the step's last day. Cost prices the step's days
# from the start.
#
# @example
#   start = TeamPlanning::SeatStart.new(position)
#   start.held_in(Date.new(2027, 1, 1)..Date.new(2027, 3, 31)) # => 2027-02-15..2027-03-31
class TeamPlanning::SeatStart
  # Each open part of each position on a map: the FTE each planned leaver
  # leaves, opening the day after they go, then the rest, opening when the
  # position does.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @return [Array<Array(TeamPlanning::Baseline::Position, Rational, SeatStart)>] position, open FTE and start
  def self.openings(map)
    filled = Hash.new(0r)
    map.people.each do |person|
      TeamPlanning::Baseline::Membership.shares(person.memberships).each do |placement, share, _|
        filled[placement.position_id] += fte_of(person) * share if placement.position_id && placement.position_id != person.backfill_id
      end
    end
    leavers = map.people.select(&:leaving?).group_by(&:backfill_id)
    map.positions.sort_by(&:id).flat_map do |position|
      open = Rational(position.fte.to_s) - filled[position.id]
      open.positive? ? parts(position, open, leavers.fetch(position.id, [])) : []
    end
  end

  # @param member [TeamPlanning::Baseline::Member]
  # @return [Rational] the FTE the plan counts, 1 when nobody knows it
  def self.fte_of(member)
    fte = member.planned_or_own(:fte)
    fte.nil? || fte == TeamPlanning::Baseline::UNKNOWN ? 1r : Rational(fte.to_s)
  end

  def self.parts(position, open, leavers)
    dated = leavers.map { [ fte_of(it), TeamPlanning::Events::DepartureSet.leaving_date(it.departure[:leaves_on]) ] }
    parts = dated.sort_by { |_, last| last || Date.new(0) }.filter_map do |fte, last|
      fte = [ fte, open ].min
      next unless fte.positive?

      open -= fte
      [ position, fte, new(position, opens_on: last&.next_day) ]
    end
    open.positive? ? parts << [ position, open, new(position) ] : parts
  end
  private_class_method :parts

  # @param position [TeamPlanning::Baseline::Position]
  # @param opens_on [Date, nil] the day this part of the seat opens; the position's own by default
  def initialize(position, opens_on: position.opened_on)
    @position = position
    @opens_on = opens_on
  end

  # @return [Boolean] recruiting is paused, so the seat stays empty
  def on_hold? = @position.hiring_status == "on_hold"

  # @return [Date, nil] the day the seat is filled from; nil for one filled
  #   from before any step, or never while on hold
  def planned = ([ @position.target_start, @opens_on ].compact.max unless on_hold?)

  # @param time_to_hire [Integer] days
  # @return [Date, nil] when an undated open seat is forecast to fill; nil
  #   when the plan dates it, or recruiting is on hold
  def forecast(time_to_hire:)
    return if on_hold? || @position.target_start || @opens_on.nil?

    @opens_on + time_to_hire
  end

  # @return [String] "on_hold", "target" or "opened"
  def basis
    return "on_hold" if on_hold?

    @position.target_start ? "target" : "opened"
  end

  # @param step [Range<Date>]
  # @return [Boolean] whether the seat has started by the step's last day
  def started_in?(step) = !on_hold? && (planned.nil? || planned <= step.end)

  # @param step [Range<Date>]
  # @return [Range<Date>, nil] the step's days from the start, nil for none
  def held_in(step)
    return unless started_in?(step)

    [ planned, step.begin ].compact.max..step.end
  end
end
