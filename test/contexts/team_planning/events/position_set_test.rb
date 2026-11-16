# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::PositionSetTest < ActiveSupport::TestCase
  IDS = { role_id: "0190A1B2-0000-7000-8000-000000000001", level_id: "0190a1b2-0000-7000-8000-000000000002",
          unit_id: "0190a1b2-0000-7000-8000-000000000003" }.freeze

  def end_state(**fields) = TeamPlanning::Events::PositionSet.end_state({ **IDS, fte: "0.5", basis: "new", **fields })

  def refusal(**fields) = assert_raises(TeamPlanning::Error) { end_state(**fields) }.message

  should "store the ids and basis downcased and the FTE as a number" do
    assert_equal({ **IDS.transform_values(&:downcase), fte: 0.5, basis: "backfill", cost_centre: nil,
                    hiring_status: "not_started", target_start: nil }, end_state(basis: " Backfill "))
  end

  should "squish a cost centre, read a blank one as none, and refuse a long one" do
    assert_equal "Eng Platform", end_state(cost_centre: "  Eng   Platform ")[:cost_centre]
    assert_nil end_state(cost_centre: " ")[:cost_centre]
    assert_equal "A position's cost centre is at most 120 characters", refusal(cost_centre: "x" * 121)
  end

  should "read an older event without a cost centre as none" do
    map = TeamPlanning::Baseline::Map.new(**TeamPlanning::Baseline::Map.members.index_with { [] })
    data = { subject_id: "0190a1b2-0000-7000-8000-000000000009", **end_state.except(:cost_centre) }
    assert_nil TeamPlanning::Events::PositionSet.apply_to(map, data).positions.sole.cost_centre
  end

  should "read a hiring status, keep a target start as a date, and refuse what neither is" do
    assert_equal({ hiring_status: "recruiting", target_start: "2027-02-01" },
                 end_state(hiring_status: " Recruiting ", target_start: "2027-02-01").slice(:hiring_status, :target_start))
    assert_equal "on_hold", end_state(hiring_status: "on_hold")[:hiring_status]
    assert_equal "A position's hiring status is one of not_started, recruiting, on_hold, offer_accepted", refusal(hiring_status: "hired")
    assert_equal "A position's target start is a date, such as 2026-05-01", refusal(target_start: "soon")
  end

  should "refuse an accepted offer without a target start" do
    assert_equal "An accepted offer needs a target start", refusal(hiring_status: "offer_accepted")
    assert_equal "2027-03-01", end_state(hiring_status: "offer_accepted", target_start: "2027-03-01")[:target_start]
  end

  should "read an older event without hiring fields as not started, with no target start" do
    map = TeamPlanning::Baseline::Map.new(**TeamPlanning::Baseline::Map.members.index_with { [] })
    data = { subject_id: "0190a1b2-0000-7000-8000-000000000009", **end_state.except(:hiring_status, :target_start) }
    position = TeamPlanning::Events::PositionSet.apply_to(map, data).positions.sole
    assert_equal "not_started", position.hiring_status
    assert_nil position.target_start
  end

  should "refuse a missing id, an FTE outside (0, 1] and an unknown basis" do
    assert_equal "A position needs level_id, unit_id", refusal(level_id: " ", unit_id: nil)
    [ 0, -1, 1.01, "half", nil ].each { assert_equal "A position's FTE is above 0 and at most 1", refusal(fte: it), it.inspect }
    assert_equal "A position is a backfill or a new one", refusal(basis: "contractor")
  end

  should "share its facet with a close, so the later of the two wins" do
    assert_equal TeamPlanning::Events::PositionSet.facet, TeamPlanning::Events::PositionClosed.facet
    assert TeamPlanning::Events::PositionSet.complete?
    assert TeamPlanning::Events::PositionClosed.complete?
  end
end
