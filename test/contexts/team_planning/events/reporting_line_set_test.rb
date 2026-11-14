# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::ReportingLineSetTest < ActiveSupport::TestCase
  KIND = TeamPlanning::Events::ReportingLineSet
  PERSON = "0190A1B2-0000-7000-8000-000000000001"
  SEAT = "0190a1b2-0000-7000-8000-000000000002"

  should "store a person, a position or neither, downcased" do
    assert_equal({ manager_id: PERSON.downcase, manager_position_id: nil }, KIND.end_state(manager_id: " #{PERSON} "))
    assert_equal({ manager_id: nil, manager_position_id: SEAT }, KIND.end_state(manager_position_id: SEAT))
    assert_equal({ manager_id: nil, manager_position_id: nil }, KIND.end_state({}))
  end

  should "refuse a person and a position at once" do
    error = assert_raises(TeamPlanning::Error) { KIND.end_state(manager_id: PERSON, manager_position_id: SEAT) }
    assert_equal "A person reports to a person or a position, not both", error.message
  end

  should "move with the Org Graph's manager fact, and nothing else" do
    change = ->(kind, fact) { OrgGraph::ChangesBetween::Change.new(kind:, fact:, person_id: PERSON, **%i[effective_on learned_at unit_id from_unit_id succession_id before after provider event_id withdrawn].index_with(nil)) }
    assert_equal PERSON, KIND.subject_moved_by(change.(:fact_changed, "manager"))
    assert_nil KIND.subject_moved_by(change.(:fact_changed, "title"))
    assert_nil KIND.subject_moved_by(change.(:left, nil))
  end
end
