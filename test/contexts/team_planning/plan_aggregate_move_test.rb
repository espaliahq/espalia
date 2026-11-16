# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateMoveTest < ActiveSupport::TestCase
  setup do
    @plan_id = SecureRandom.uuid_v7
    @ada_id = SecureRandom.uuid_v7
    @grace_id = SecureRandom.uuid_v7
    @eng_id = SecureRandom.uuid_v7
    @sales_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @ada_id)
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @q2 = fork(@q1, "then", ends_on: "2027-06-30")
    @q3 = fork(@q2, "then", ends_on: "2027-09-30")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: "Step", ends_on:, forked_by_id: @ada_id)
    end
  end

  def last_event = @plan.unpublished_events.to_a.last

  def place(scenario_id, unit_id, person_id: @grace_id)
    @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id:, subject_id: person_id, set_by_id: @ada_id,
                                                          end_state: { placements: [ { unit_id:, allocation: 1.0 } ] })
    last_event.event_id
  end

  def leave(scenario_id, leaves_on: nil)
    @plan.set_change(TeamPlanning::Events::DepartureSet, scenario_id:, subject_id: @grace_id, set_by_id: @ada_id,
                                                         end_state: { leaves_in_id: scenario_id, leaves_on: }.compact)
    last_event.event_id
  end

  def move(scenario_id, direction, facet: "assignment", to_scenario_id: nil)
    @plan.move_change(scenario_id:, subject_id: @grace_id, facet:, direction:, to_scenario_id:, moved_by_id: @ada_id)
    last_event.event_id
  end

  def open_position(scenario_id, position_id)
    @plan.set_change(TeamPlanning::Events::PositionSet, scenario_id:, subject_id: position_id, set_by_id: @ada_id,
                                                        end_state: { role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7, unit_id: @eng_id, fte: 1, basis: "new" })
    last_event.event_id
  end

  def place_in_position(scenario_id, position_id)
    @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id:, subject_id: @grace_id, set_by_id: @ada_id,
                                                          end_state: { placements: [ { position_id:, allocation: 1.0 } ] })
    last_event.event_id
  end

  def undo(scenario_id, event_id) = @plan.undo_change(scenario_id:, event_id:, undone_by_id: @ada_id)

  def resolved(scenario_id) = @plan.winning_changes(scenario_id).transform_values { [ it.event_id, it.data ] }

  def everything = [ @plan_id, *@plan.scenarios.keys ].to_h { [ it, [ resolved(it), @plan.log_of(it).map(&:event_id) ] ] }

  def replayed = TeamPlanning::PlanAggregate.new.tap { |plan| @plan.unpublished_events.each { plan.apply(it) } }

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  def key = [ @grace_id, "assignment" ]

  test "move a change a step later, so the step it left follows its parent there" do
    placed = place(@q1, @eng_id)
    move(@q1, "later")

    assert_nil @plan.winning_changes(@q1)[key]
    assert_equal placed, @plan.winning_changes(@q2)[key].event_id
    assert_equal @q2, @plan.winning_changes(@q2)[key].data[:scenario_id]
    assert_equal placed, @plan.winning_changes(@q3)[key].event_id
  end

  test "move a change a step earlier, into the step before on the path" do
    placed = place(@q2, @eng_id)
    move(@q2, "earlier")

    assert_equal placed, @plan.winning_changes(@q1)[key].event_id
    assert_empty @plan.changes_in(@q2)
  end

  test "take every entry of the key along, undone ones too, so undo and redo behave as before" do
    first = place(@q1, @eng_id)
    second = place(@q1, @sales_id)
    @plan.undo_change(scenario_id: @q1, event_id: second, undone_by_id: @ada_id)
    move(@q1, "later")

    @plan.redo_change(scenario_id: @q2, event_id: second, redone_by_id: @ada_id)

    assert_equal [ first, second ], @plan.changes_in(@q2).map(&:event_id)
  end

  test "move from an alternative earlier past the step it stands in for" do
    alternative = fork(@q2, "instead")
    placed = place(alternative, @eng_id)
    move(alternative, "earlier")

    assert_equal placed, @plan.winning_changes(@q1)[key].event_id
  end

  test "ask which step when more than one follows, and move into the one named" do
    alternative = fork(@q2, "instead")
    place(@q1, @eng_id)

    assert_match "name the step", refusal { move(@q1, "later") }
    assert_match "isn't a step after", refusal { move(@q1, "later", to_scenario_id: @q3) }

    move(@q1, "later", to_scenario_id: alternative)

    assert_equal alternative, @plan.changes_in(alternative).sole.data[:scenario_id]
  end

  test "refuse a move into the baseline, past the last step or out of a step that doesn't change it" do
    place(@q1, @eng_id)
    place(@q3, @sales_id)

    assert_match "baseline", refusal { move(@q1, "earlier") }
    assert_match "no step after", refusal { move(@q3, "later") }
    assert_match "nothing to move", refusal { move(@q2, "later") }
  end

  test "refuse a move into a step that already changes it, naming that change" do
    place(@q1, @eng_id)
    there = place(@q2, @sales_id)

    assert_match there, refusal { move(@q1, "later") }
  end

  test "refuse a facet that doesn't move between steps" do
    assert_match "Only a place, a position or a departure", refusal { move(@q1, "later", facet: "level") }
  end

  test "refuse a move into or out of either half of a split step" do
    placed = place(@q2, @eng_id)
    place(@q2, @sales_id, person_id: @ada_id)
    @plan.split_scenario(@q2, agreed_id: SecureRandom.uuid_v7, name: "Agreed", event_ids: [ placed ], split_by_id: @ada_id)
    place(@q1, @eng_id, person_id: @ada_id)

    assert_match "split", refusal { @plan.move_change(scenario_id: @q1, subject_id: @ada_id, facet: "assignment", direction: "later", moved_by_id: @ada_id) }
    assert_match "split", refusal { @plan.move_change(scenario_id: @q2, subject_id: @ada_id, facet: "assignment", direction: "earlier", moved_by_id: @ada_id) }
  end

  test "refuse a departure whose date falls outside the step it would move to, naming the date and the period" do
    leave(@q1, leaves_on: "2027-02-14")

    message = refusal { move(@q1, "later", facet: "departure") }

    assert_match "2027-02-14", message
    assert_match "2027-04-01 to 2027-06-30", message
  end

  test "a departure that moves leaves in the step it moved to" do
    leave(@q1)
    move(@q1, "later", facet: "departure")

    assert_equal @q2, @plan.changes_in(@q2).sole.data[:leaves_in_id]
  end

  test "undo a move as one step, and redo it, each leaving every step as it resolved" do
    place(@q1, @eng_id)
    place(@q1, @sales_id, person_id: @ada_id)
    before = everything
    moved = move(@q1, "later")
    after = everything

    @plan.undo_change(scenario_id: @q2, event_id: moved, undone_by_id: @ada_id)
    assert_equal before.transform_values(&:first), everything.transform_values(&:first)
    assert_equal before[@q1].last, everything[@q1].last

    @plan.redo_change(scenario_id: @q2, event_id: moved, redone_by_id: @ada_id)
    assert_equal after, everything
    assert_equal everything, replayed.then { |plan| [ @plan_id, *plan.scenarios.keys ].to_h { [ it, [ plan.winning_changes(it).transform_values { |c| [ c.event_id, c.data ] }, plan.log_of(it).map(&:event_id) ] ] } }
  end

  test "the Undo button takes back the move, and Redo puts it back" do
    place(@q1, @eng_id)
    moved = move(@q1, "later")

    assert_equal moved, @plan.last_undoable_by(@q2, @ada_id)
    @plan.undo_change(scenario_id: @q2, event_id: moved, undone_by_id: @ada_id)
    assert_equal moved, @plan.last_redoable_by(@q2, @ada_id)
  end

  test "refuse to undo a move once the step it left changes the same thing, naming that change" do
    place(@q1, @eng_id)
    moved = move(@q1, "later")
    again = place(@q1, @sales_id)

    assert_match again, refusal { @plan.undo_change(scenario_id: @q2, event_id: moved, undone_by_id: @ada_id) }
  end

  test "refuse to undo a move once a later change in the step it reached replaced it, naming that change" do
    place(@q1, @eng_id)
    moved = move(@q1, "later")
    later = place(@q2, @sales_id)

    assert_match later, refusal { @plan.undo_change(scenario_id: @q2, event_id: moved, undone_by_id: @ada_id) }
  end

  test "a pay change on the same person stays where it was made" do
    place(@q1, @eng_id)
    @plan.set_change(TeamPlanning::Events::PlanDataSet, scenario_id: @q1, subject_id: @grace_id, set_by_id: @ada_id,
                                                        end_state: { field: "pay", value: { amount: "100000", currency: "AUD", period: "year", basis: "actual" } })
    pay = last_event.event_id
    move(@q1, "later")

    assert_equal [ pay ], @plan.changes_in(@q1).map(&:event_id)
  end

  test "undo two moves of one change in turn, each putting it back a step" do
    placed = place(@q1, @eng_id)
    first = move(@q1, "later")
    second = move(@q2, "later")

    undo(@q3, second)
    assert_equal placed, @plan.winning_changes(@q2)[key].event_id
    undo(@q2, first)

    assert_equal [ placed ], @plan.changes_in(@q1).map(&:event_id)
    assert_nil @plan.winning_changes(@plan_id)[key]
  end

  test "undoing a move puts its entries back in their order, so a clear made after a change still clears it" do
    place(@q2, @eng_id)
    @plan.clear_change(scenario_id: @q2, subject_id: @grace_id, facet: "assignment", cleared_by_id: @ada_id)
    arrived = place(@q1, @sales_id)
    move(@q1, "later")
    onward = move(@q2, "later")

    undo(@q3, onward)

    assert_equal arrived, @plan.winning_changes(@q2)[key].event_id
    assert_equal everything, replayed.then { |plan| [ @plan_id, *plan.scenarios.keys ].to_h { [ it, [ plan.winning_changes(it).transform_values { |c| [ c.event_id, c.data ] }, plan.log_of(it).map(&:event_id) ] ] } }
  end

  test "refuse to move a position later while a change left behind places someone in it" do
    position_id = SecureRandom.uuid_v7
    opened = open_position(@q1, position_id)
    placed = place_in_position(@q1, position_id)

    assert_match placed, refusal { @plan.move_change(scenario_id: @q1, subject_id: position_id, facet: "position", direction: "later", moved_by_id: @ada_id) }
    assert_equal [ opened, placed ], @plan.changes_in(@q1).map(&:event_id)
  end

  test "refuse to move a placement earlier than the position it fills, naming the position" do
    position_id = SecureRandom.uuid_v7
    opened = open_position(@q2, position_id)
    place_in_position(@q2, position_id)

    assert_match opened, refusal { move(@q2, "earlier") }
  end

  test "refuse to undo a move that would leave a later change without the position it moved" do
    position_id = SecureRandom.uuid_v7
    open_position(@q2, position_id)
    moved = @plan.move_change(scenario_id: @q2, subject_id: position_id, facet: "position", direction: "earlier", moved_by_id: @ada_id).then { last_event.event_id }
    place_in_position(@q1, position_id)

    assert_match "can't move later", refusal { undo(@q1, moved) }
  end

  test "refuse to move an alternative's change earlier past the step it stands in for when that step changes it too" do
    alternative = fork(@q2, "instead")
    there = place(@q2, @sales_id)
    place(alternative, @eng_id)

    assert_match there, refusal { move(alternative, "earlier") }
  end

  test "refuse to undo a departure's move into a step whose period doesn't hold its date" do
    leave(@q1, leaves_on: "2027-03-14")
    @plan.set_scenario_period(@q1, ends_on: "2027-02-28", set_by_id: @ada_id)
    moved = move(@q1, "later", facet: "departure")

    assert_match "2027-03-14", refusal { undo(@q2, moved) }
  end

  test "refuse a step named for a move earlier" do
    place(@q2, @eng_id)

    assert_match "name no step", refusal { move(@q2, "earlier", to_scenario_id: @q3) }
  end

  def redo_move(scenario_id, event_id) = @plan.redo_change(scenario_id:, event_id:, redone_by_id: @ada_id)

  test "refuse to move a change with an unsettled conflict from the last update to today, pointing at the Changes tab" do
    placed = place(@q1, @eng_id)
    @plan.rebase(base_on: "2027-02-10", expected_base_on: "2027-01-01", rebased_by_id: @ada_id,
                 conflicts: [ { scenario_id: @q1, subject_id: @grace_id, facet: "assignment", change_id: placed } ])

    assert_match "Changes tab", refusal { move(@q1, "later") }
    assert_equal placed, @plan.winning_changes(@q1)[key].event_id
  end

  test "refuse to move a change earlier while its conflict from the last update to today is unsettled" do
    placed = place(@q2, @eng_id)
    @plan.rebase(base_on: "2027-02-10", expected_base_on: "2027-01-01", rebased_by_id: @ada_id,
                 conflicts: [ { scenario_id: @q2, subject_id: @grace_id, facet: "assignment", change_id: placed } ])

    assert_match "Changes tab", refusal { move(@q2, "earlier") }
  end


  test "undo a second move back to the place the first one left the change in" do
    placed = place(@q1, @eng_id)
    there = place(@q2, @sales_id, person_id: @ada_id)
    first = move(@q1, "later")
    second = move(@q2, "later")

    undo(@q3, second)

    assert_equal [ there, placed, first ], @plan.log_of(@q2).map(&:event_id)
  end

  test "refuse to undo a move when a step in between has since changed it" do
    alternative = fork(@q2, "instead")
    place(alternative, @eng_id)
    moved = move(alternative, "earlier")
    there = place(@q2, @sales_id)

    assert_match there, refusal { undo(@q1, moved) }
  end

  test "refuse to redo a move when a step in between has since changed it" do
    alternative = fork(@q2, "instead")
    place(alternative, @eng_id)
    moved = move(alternative, "earlier")
    undo(@q1, moved)
    there = place(@q2, @sales_id)

    assert_match there, refusal { redo_move(@q1, moved) }
  end

  test "refuse to redo a move once its change has moved somewhere else" do
    placed = place(@q2, @eng_id)
    moved = move(@q2, "later")
    undo(@q3, moved)
    move(@q2, "earlier")

    assert_match "moved again", refusal { redo_move(@q3, moved) }
    assert_equal placed, @plan.winning_changes(@q1)[key].event_id
  end

  test "refuse to undo a move once an earlier move's undo has taken its change back" do
    place(@q1, @eng_id)
    first = move(@q1, "later")
    second = move(@q2, "later")
    undo(@q3, first)

    assert_match "moved again", refusal { undo(@q3, second) }
  end
end
