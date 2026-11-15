# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateSplitTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
  end

  setup do
    @plan_id = SecureRandom.uuid_v7
    @ada_id = SecureRandom.uuid_v7
    @grace_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @ada_id)
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @q2 = fork(@q1, "then", ends_on: "2027-06-30")
    @lean = fork(@q1, "instead")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: "Step", ends_on:, forked_by_id: @ada_id)
    end
  end

  def last_event = @plan.unpublished_events.to_a.last

  def set(scenario_id, title, subject_id: "lin", by: @ada_id)
    @plan.set_change(TitleSet, scenario_id:, subject_id:, set_by_id: by, end_state: { title: })
    last_event.event_id
  end

  def set_unit(scenario_id, unit_id, parent_id: nil)
    @plan.set_change(TeamPlanning::Events::UnitSet, scenario_id:, subject_id: unit_id, set_by_id: @ada_id,
                                                    end_state: { name: "Payments", parent_id:, level_id: @level_id })
    last_event.event_id
  end

  def place(scenario_id, person_id, unit_id)
    @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id:, subject_id: person_id, set_by_id: @ada_id,
                                                          end_state: { placements: [ { unit_id:, allocation: 1.0 } ] })
    last_event.event_id
  end

  def split(scenario_id, *event_ids, standing_ids: Set.new)
    SecureRandom.uuid_v7.tap do
      @plan.split_scenario(scenario_id, agreed_id: it, name: "Agreed", event_ids:, standing_ids:, split_by_id: @ada_id)
    end
  end

  def resolved(scenario_id) = @plan.winning_changes(scenario_id).transform_values(&:event_id)

  def everything = (@plan.scenarios.keys + [ @plan_id ]).to_h { [ it, resolved(it) ] }

  def replayed = TeamPlanning::PlanAggregate.new.tap { |plan| @plan.unpublished_events.each { plan.apply(it) } }

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "move the named changes into the agreed part beneath, and resolve every scenario as before" do
    title = set(@q1, "Lead", subject_id: "lin")
    other = set(@q1, "Staff", subject_id: "ola")
    set(@q2, "Principal", subject_id: "ola")
    before = everything

    agreed = split(@q1, title)

    assert_equal [ title ], @plan.changes_in(agreed).map(&:event_id)
    assert_equal [ other ], @plan.changes_in(@q1).map(&:event_id)
    assert_equal before, everything.except(agreed)
    assert_equal({ [ "lin", "title" ] => title }, resolved(agreed))
  end

  should "put the agreed part in the original's place, with the original on it over the same period" do
    set(@q1, "Staff", subject_id: "ola")
    agreed = split(@q1, set(@q1, "Lead"))

    assert_equal [ @plan_id, "then" ], @plan.scenarios.fetch(agreed).to_h.values_at(:parent_id, :relation)
    assert_equal [ agreed, "on" ], @plan.scenarios.fetch(@q1).to_h.values_at(:parent_id, :relation)
    assert_equal @plan.period_of(@q1), @plan.period_of(agreed)
    assert_equal Date.new(2027, 1, 1)..Date.new(2027, 3, 31), @plan.period_of(@q1)
    assert_equal Date.new(2027, 4, 1), @plan.period_of(@q2).begin
  end

  should "keep one timeline column for the pair, and keep the original's alternatives and next step" do
    set(@q1, "Staff", subject_id: "ola")
    agreed = split(@q1, set(@q1, "Lead"))

    assert_equal [ @plan_id, @q1 ], @plan.timeline_path(@q1)
    assert_equal [ @plan_id, agreed ], @plan.timeline_path(agreed)
    assert_equal [ @plan_id, @q1, @q2 ], @plan.timeline_path(@q2)
    assert_equal [ @plan_id, @lean ], @plan.timeline_path(@lean)
    assert_equal [ @plan_id, agreed, @q1, @lean ], @plan.resolution_chain(@lean)
    assert @plan.split?(@q1)
    assert @plan.split?(agreed)
    assert_not @plan.split?(@q2)
    assert_equal [ @q1 ], @plan.resting_on(agreed)
  end

  should "take every earlier change of a moved subject and facet across, so none is left behind to win" do
    first = set(@q1, "Senior")
    latest = set(@q1, "Lead")
    staying = set(@q1, "Staff", subject_id: "ola")

    agreed = split(@q1, latest)

    assert_equal [ first, latest ], @plan.changes_in(agreed).map(&:event_id)
    assert_equal [ staying ], @plan.changes_in(@q1).map(&:event_id)
    assert_equal latest, resolved(@q1)[[ "lin", "title" ]]
  end

  should "resolve the same after an undo or redo in either part as it would have before the split" do
    undone = set(@q1, "Senior")
    @plan.undo_change(scenario_id: @q1, event_id: undone, undone_by_id: @ada_id)
    latest = set(@q1, "Lead", by: @grace_id)
    staying = set(@q1, "Staff", subject_id: "ola")
    unsplit = replayed

    agreed = split(@q1, latest)
    [ [ @plan, agreed ], [ unsplit, @q1 ] ].each do |plan, scenario_id|
      plan.undo_change(scenario_id:, event_id: latest, undone_by_id: @grace_id)
      plan.undo_change(scenario_id: @q1, event_id: staying, undone_by_id: @ada_id)
    end
    assert_equal unsplit.winning_changes(@q2).transform_values(&:event_id), resolved(@q2)

    [ [ @plan, agreed ], [ unsplit, @q1 ] ].each do |plan, scenario_id|
      plan.redo_change(scenario_id:, event_id: undone, redone_by_id: @ada_id)
      plan.redo_change(scenario_id: @q1, event_id: staying, redone_by_id: @ada_id)
    end
    assert_equal unsplit.winning_changes(@q2).transform_values(&:event_id), resolved(@q2)
    assert_equal undone, resolved(@q2)[[ "lin", "title" ]]

    [ [ @plan, agreed ], [ unsplit, @q1 ] ].each do |plan, scenario_id|
      plan.undo_change(scenario_id:, event_id: undone, undone_by_id: @ada_id)
      plan.redo_change(scenario_id:, event_id: latest, redone_by_id: @grace_id)
    end
    assert_equal unsplit.winning_changes(@q2).transform_values(&:event_id), resolved(@q2)
    assert_equal latest, @plan.last_undoable_by(agreed, @grace_id)
    assert_equal latest, resolved(@q2)[[ "lin", "title" ]]
  end

  should "carry each moved change's redo slot into the agreed part, and leave the rest's with the original" do
    kept = set(@q1, "Lead")
    moved = set(@q1, "Senior")
    @plan.undo_change(scenario_id: @q1, event_id: moved, undone_by_id: @ada_id)
    set(@q1, "Principal", subject_id: "kim", by: @grace_id)
    staying = set(@q1, "Staff", subject_id: "ola", by: @grace_id)
    @plan.undo_change(scenario_id: @q1, event_id: staying, undone_by_id: @grace_id)

    agreed = split(@q1, kept)

    assert_equal [ kept, moved ], @plan.log_of(agreed).map(&:event_id)
    assert_equal moved, @plan.last_redoable_by(agreed, @ada_id)
    assert_nil @plan.last_redoable_by(@q1, @ada_id)
    assert_equal staying, @plan.last_redoable_by(@q1, @grace_id)
    assert_nil @plan.last_redoable_by(agreed, @grace_id)
  end

  should "name the change that blocks a split: a person placed in a unit only the rest creates" do
    unit_id = SecureRandom.uuid_v7
    creates = set_unit(@q1, unit_id)
    placed = place(@q1, "ola", unit_id)

    error = assert_raises(TeamPlanning::SplitBlocked) { split(@q1, placed) }

    assert_equal [ [ creates, unit_id, "unit", placed ] ], error.blocks.map(&:to_h).map(&:values)
    assert_match "unit of #{unit_id}", error.message
    assert_empty @plan.unpublished_events.select { it.is_a?(TeamPlanning::Events::ScenarioSplit) }
  end

  should "block a split when an earlier change that moves with it, and an undo could bring back, needs what the rest creates" do
    parent_id = SecureRandom.uuid_v7
    child_id = SecureRandom.uuid_v7
    creates = set_unit(@q1, parent_id)
    under = set_unit(@q1, child_id, parent_id:)
    alone = set_unit(@q1, child_id)

    error = assert_raises(TeamPlanning::SplitBlocked) { split(@q1, alone) }
    assert_equal [ [ creates, under ] ], error.blocks.map { [ it.event_id, it.blocks_event_id ] }
  end

  should "let a change move when what it needs stands in the parent or moves with it" do
    standing_id = SecureRandom.uuid_v7
    set_unit(@q1, standing_id)
    placed = place(@q1, "ola", standing_id)
    assert split(@q1, placed, standing_ids: Set[standing_id])

    unit_id = SecureRandom.uuid_v7
    creates = set_unit(@q2, unit_id)
    child = set_unit(@q2, SecureRandom.uuid_v7, parent_id: unit_id)
    set(@q2, "Staff")
    agreed = split(@q2, creates, child)
    assert_equal [ creates, child ], @plan.changes_in(agreed).map(&:event_id)
  end

  should "let the rest depend on the agreed part" do
    unit_id = SecureRandom.uuid_v7
    creates = set_unit(@q1, unit_id)
    place(@q1, "ola", unit_id)

    agreed = split(@q1, creates)

    assert_equal [ creates ], @plan.changes_in(agreed).map(&:event_id)
  end

  should "refuse a split of the baseline, of nothing, of everything, or of a change not in effect there" do
    lead = set(@q1, "Lead")
    other = set(@q2, "Staff")

    assert_equal "The baseline can't be split", refusal { split(@plan_id, lead) }
    assert_equal "Name the changes that move into the agreed part", refusal { split(@q1) }
    assert_equal "Every change would move: approve the scenario whole instead", refusal { split(@q1, lead) }
    assert_equal "This scenario has no change #{other} in effect to move", refusal { split(@q1, other) }
  end

  should "move a split step's end through either part, and refuse a second next step after the agreed part" do
    set(@q1, "Staff", subject_id: "ola")
    agreed = split(@q1, set(@q1, "Lead"))

    @plan.set_scenario_period(@q1, ends_on: "2027-04-30", set_by_id: @ada_id)

    assert_equal agreed, last_event.data[:scenario_id]
    assert_equal Date.new(2027, 4, 30), @plan.period_of(@q1).end
    assert_equal Date.new(2027, 5, 1), @plan.period_of(@q2).begin
    assert_equal "This is the agreed part of a split step: fork the next step from the rest, which sits on it",
                 refusal { fork(agreed, "then", ends_on: "2027-12-31") }
    assert_equal "A scenario forks as then or instead", refusal { fork(@q1, "on") }
  end

  should "split a split again, and replay the stream to the same plan" do
    set(@q1, "Staff", subject_id: "ola")
    set(@q1, "Senior", subject_id: "kim")
    set(@q1, "Lead", subject_id: "lin")
    first = split(@q1, @plan.changes_in(@q1).first.event_id)
    second = split(@q1, @plan.changes_in(@q1).first.event_id)

    assert_equal [ @plan_id, first, second, @q1 ], @plan.resolution_chain(@q1)
    assert_equal [ @plan_id, @q1 ], @plan.timeline_path(@q1)

    replay = replayed
    assert_equal everything, (replay.scenarios.keys + [ @plan_id ]).to_h { [ it, replay.winning_changes(it).transform_values(&:event_id) ] }
    assert_equal @plan.scenarios, replay.scenarios
  end
end
