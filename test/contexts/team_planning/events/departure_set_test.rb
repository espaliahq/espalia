# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::DepartureSetTest < ActiveSupport::TestCase
  KIND = TeamPlanning::Events::DepartureSet
  STEP = "0190A1B2-0000-7000-8000-000000000001"
  SEAT = "0190a1b2-0000-7000-8000-000000000002"

  should "store the step they leave in and their backfill, downcased, with no backfill allowed" do
    assert_equal({ leaves_in_id: STEP.downcase, position_id: SEAT }, KIND.end_state(leaves_in_id: STEP, position_id: " #{SEAT} "))
    assert_equal({ leaves_in_id: STEP.downcase, position_id: nil }, KIND.end_state(leaves_in_id: STEP))
  end

  should "refuse a departure that names no step" do
    assert_equal "A departure names the step the person leaves in", assert_raises(TeamPlanning::Error) { KIND.end_state(position_id: SEAT) }.message
  end

  should "share its facet with a withdrawal, so the later of the two wins" do
    assert_equal KIND.facet, TeamPlanning::Events::DepartureWithdrawn.facet
    assert KIND.complete?
    assert TeamPlanning::Events::DepartureWithdrawn.complete?
    assert KIND.readable?
  end
end
