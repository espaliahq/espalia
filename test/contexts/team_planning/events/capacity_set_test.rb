# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::CapacitySetTest < ActiveSupport::TestCase
  KIND = TeamPlanning::Events::CapacitySet
  SEAT = "0190A1B2-0000-7000-8000-000000000002"

  should "store the place downcased and the amount as the decimal it was given" do
    assert_equal({ position_id: SEAT.downcase, unit_id: nil, amount: "0.75" }, KIND.end_state(position_id: " #{SEAT} ", amount: " 0.75 "))
    assert_equal({ position_id: nil, unit_id: SEAT.downcase, amount: "0" }, KIND.end_state(unit_id: SEAT, amount: 0))
  end

  should "refuse an override for no place, for two, or for an amount that isn't 0 or more" do
    refusal = ->(end_state) { assert_raises(TeamPlanning::Error) { KIND.end_state(end_state) }.message }
    assert_equal "An override names the position or unit it is for", refusal.call(amount: "1")
    assert_equal "An override is for a position or a unit, not both", refusal.call(position_id: SEAT, unit_id: SEAT, amount: "1")
    [ "-1", "", "one", "1e3", nil ].each { assert_equal "An override is a number of units, 0 or more", refusal.call(unit_id: SEAT, amount: it) }
  end

  should "give each place its own facet, so clearing one keeps the others" do
    assert KIND.holds?("capacity:#{SEAT.downcase}")
    [ "assignment", "capacity:", "capacity:Payments", "capacity:#{SEAT}" ].each { assert_not KIND.holds?(it), it }
  end
end
