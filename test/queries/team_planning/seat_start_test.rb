# frozen_string_literal: true

require "test_helper"

class TeamPlanning::SeatStartTest < ActiveSupport::TestCase
  STEP = Date.new(2026, 4, 1)..Date.new(2026, 6, 30)

  def position(opened_on: Date.new(2026, 3, 2), **hiring)
    TeamPlanning::Baseline::Position.new(id: "p", role_id: "r", level_id: "l", unit_id: "u", fte: 1, basis: "new",
                                         role_name: nil, level_name: nil, opened_on:, **hiring)
  end

  def start(...) = TeamPlanning::SeatStart.new(position(...))

  should "open each earlier leaver's share on its own day, the rest when the seat opens, and never more than the seat has open" do
    vacated = ->(fte, on) { TeamPlanning::Baseline::Vacated.new(fte:, opens_on: on) }
    opens = lambda do |*parts|
      map = TeamPlanning::Baseline::Map.new(base_on: nil, known_on: nil, units: [], people: [], unassigned_ids: [], positions: [ position(vacated: parts) ],
                                            names: {}, rules: nil)
      TeamPlanning::SeatStart.openings(map).map { |_, fte, seat| [ fte, seat.planned ] }
    end

    assert_equal [ [ 1/2r, Date.new(2026, 3, 2) ], [ 1/4r, Date.new(2026, 4, 16) ], [ 1/4r, Date.new(2026, 5, 16) ] ],
                 opens.(vacated.(1/4r, Date.new(2026, 5, 16)), vacated.(1/4r, Date.new(2026, 4, 16))).sort_by(&:last)
    assert_equal [ [ 1r, Date.new(2026, 4, 16) ] ], opens.(vacated.(1r, Date.new(2026, 4, 16)), vacated.(1r, Date.new(2026, 5, 16)))
  end

  should "hold an undated seat for the whole step it is open in" do
    assert_equal STEP, start.held_in(STEP)
    assert_equal "opened", start.basis
  end

  should "hold a seat from its target start, and not at all when the start falls after the step" do
    assert_equal Date.new(2026, 5, 4)..STEP.end, start(target_start: Date.new(2026, 5, 4)).held_in(STEP)
    assert start(target_start: STEP.end).started_in?(STEP)
    assert_not start(target_start: STEP.end.next_day).started_in?(STEP)
    assert_nil start(target_start: STEP.end.next_day).held_in(STEP)
  end

  should "never start a seat before it opens" do
    assert_equal Date.new(2026, 5, 1), start(opened_on: Date.new(2026, 5, 1), target_start: Date.new(2026, 4, 1)).planned
  end

  should "leave a seat empty while recruiting is on hold" do
    held = start(hiring_status: "on_hold", target_start: Date.new(2026, 4, 1))

    assert_not held.started_in?(STEP)
    assert_nil held.planned
    assert_nil held.forecast(time_to_hire: 90, today: STEP.begin)
    assert_equal "on_hold", held.basis
  end

  should "forecast only an undated seat, from the day it opens" do
    assert_equal Date.new(2026, 5, 31), start.forecast(time_to_hire: 90, today: STEP.begin)
    assert_nil start(target_start: Date.new(2026, 5, 4)).forecast(time_to_hire: 90, today: STEP.begin)
  end

  should "never forecast a seat still open as filled before today" do
    assert_equal Date.new(2026, 8, 1), start.forecast(time_to_hire: 90, today: Date.new(2026, 8, 1))
    assert_equal Date.new(2026, 5, 31), start.forecast(time_to_hire: 90, today: Date.new(2026, 5, 31))
  end
end
