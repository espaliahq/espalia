# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::PositionSetTest < ActiveSupport::TestCase
  IDS = { role_id: "0190A1B2-0000-7000-8000-000000000001", level_id: "0190a1b2-0000-7000-8000-000000000002",
          unit_id: "0190a1b2-0000-7000-8000-000000000003" }.freeze

  def end_state(**fields) = TeamPlanning::Events::PositionSet.end_state({ **IDS, fte: "0.5", basis: "new", **fields })

  def refusal(**fields) = assert_raises(TeamPlanning::Error) { end_state(**fields) }.message

  should "store the ids and basis downcased and the FTE as a number" do
    assert_equal({ **IDS.transform_values(&:downcase), fte: 0.5, basis: "backfill" }, end_state(basis: " Backfill "))
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
