# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregatePeriodUndoTest < ActiveSupport::TestCase
  setup do
    @plan_id = SecureRandom.uuid_v7
    @editor_id = SecureRandom.uuid_v7
    @other_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @editor_id, time_zone: "UTC")
    @q1 = fork(ends_on: "2027-03-31")
    @q2 = fork(@q1, name: "Q2", ends_on: "2027-06-30")
  end

  def fork(parent_id = @plan_id, relation: "then", name: "Q1", ends_on: nil, starts_on: nil)
    id = SecureRandom.uuid_v7
    @plan.fork_scenario(id, parent_id:, relation:, name:, ends_on:, starts_on:, forked_by_id: @editor_id)
    id
  end

  def set(id, ends_on:, starts_on: nil, by: @editor_id)
    @plan.set_scenario_period(id, ends_on:, starts_on:, set_by_id: by)
    last_event.event_id
  end

  def place(id, subject_id: SecureRandom.uuid_v7)
    @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: id, subject_id:, set_by_id: @editor_id,
                                                          end_state: { placements: [ { unit_id: SecureRandom.uuid_v7, allocation: 1.0 } ] })
    last_event.event_id
  end

  def undo_edit(id, event_id, by: @editor_id) = @plan.undo_change(scenario_id: id, event_id:, undone_by_id: by)

  def redo_edit(id, event_id, by: @editor_id) = @plan.redo_change(scenario_id: id, event_id:, redone_by_id: by)

  def period(id) = @plan.period_of(id).then { [ it.begin.iso8601, it.end&.iso8601 ] }

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  def last_event = @plan.unpublished_events.to_a.last

  def replayed = TeamPlanning::PlanAggregate.new.tap { |plan| @plan.unpublished_events.each { plan.apply(it) } }

  context "undoing a date edit" do
    should "restore the step's old end, move the next step's start back with it, and say what it reverses" do
      edit = set(@q1, ends_on: "2027-02-28")
      assert_equal %w[2027-03-01 2027-06-30], period(@q2)

      undo_edit(@q1, edit)

      assert_kind_of TeamPlanning::Events::ScenarioPeriodSet, last_event
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: "2027-03-31",
                     previous_starts_on: "2027-01-01", previous_ends_on: "2027-02-28", set_by_id: @editor_id,
                     undoes_event_id: edit }, last_event.data)
      assert_equal %w[2027-01-01 2027-03-31], period(@q1)
      assert_equal %w[2027-04-01 2027-06-30], period(@q2)
      assert @plan.undone?(edit)
      assert_equal "dates", @plan.facet_of(@q1, edit)
      assert_equal @plan.period_of(@q2), replayed.period_of(@q2)
    end

    should "restore a first step's start, and the end of a step left open" do
      start = set(@q1, starts_on: "2027-01-15", ends_on: "2027-03-31")
      undo_edit(@q1, start)
      assert_equal %w[2027-01-01 2027-03-31], period(@q1)

      open = set(@q2, ends_on: nil)
      assert_nil @plan.period_of(@q2).end
      undo_edit(@q2, open)
      assert_equal %w[2027-04-01 2027-06-30], period(@q2)
    end

    should "redo an undone edit, and refuse to redo one that isn't undone" do
      edit = set(@q1, ends_on: "2027-02-28")
      undo_edit(@q1, edit)
      redo_edit(@q1, edit)

      assert_equal({ redoes_event_id: edit, ends_on: "2027-02-28", previous_ends_on: "2027-03-31" },
                   last_event.data.slice(:redoes_event_id, :ends_on, :previous_ends_on))
      assert_equal %w[2027-03-01 2027-06-30], period(@q2)
      assert_not @plan.undone?(edit)
      assert_equal "That change isn't undone, so there is nothing to redo", refusal { redo_edit(@q1, edit) }
      undo_edit(@q1, edit)
      assert_equal "That change is already undone", refusal { undo_edit(@q1, edit) }
    end

    should "take back only a step's latest standing edit" do
      first = set(@q1, ends_on: "2027-02-28")
      second = set(@q1, ends_on: "2027-02-15")

      assert_equal "A later change to these dates replaced it (#{second}): undo that first, then undo this", refusal { undo_edit(@q1, first) }
      undo_edit(@q1, second)
      undo_edit(@q1, first)
      assert_equal %w[2027-01-01 2027-03-31], period(@q1)

      third = set(@q1, ends_on: "2027-03-15")
      assert_equal "A later change to these dates replaced it (#{third}): undo that first, then redo this", refusal { redo_edit(@q1, first) }
    end

    should "refuse an undo that would leave a later step ending before it starts, naming it" do
      edit = set(@q1, ends_on: "2027-01-31")
      set(@q2, ends_on: "2027-03-15")

      error = assert_raises(TeamPlanning::PeriodInverted) { undo_edit(@q1, edit) }
      assert_equal @q2, error.scenario_id
      assert_equal "A scenario after it would end on 2027-03-15, before it starts on 2027-04-01", error.message
    end

    should "refuse an undo that would strand a departure" do
      edit = set(@q1, ends_on: "2027-04-30")
      @plan.set_change(TeamPlanning::Events::DepartureSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7, set_by_id: @editor_id,
                                                           end_state: { leaves_in_id: @q1, leaves_on: "2027-04-20" })

      assert_equal "Someone leaves on 2027-04-20, outside the dates this gives the scenario they leave in " \
                   "(2027-01-01 to 2027-03-31): change their date first", refusal { undo_edit(@q1, edit) }
    end

    should "refuse an undo of a first step's start once the base has moved past it" do
      edit = set(@q1, starts_on: "2027-01-20", ends_on: "2027-03-31")
      @plan.rebase(base_on: "2027-01-10", expected_base_on: "2027-01-01", conflicts: [], rebased_by_id: @editor_id, time_zone: "UTC")

      assert_equal "A first step starts on or after the plan's base date, 2027-01-10", refusal { undo_edit(@q1, edit) }
    end

    should "undo and redo an edit that moved only a first step's end, after the base moved past its old start" do
      edit = set(@q1, ends_on: "2027-04-30")
      @plan.rebase(base_on: "2027-01-10", expected_base_on: "2027-01-01", conflicts: [], rebased_by_id: @editor_id, time_zone: "UTC")

      undo_edit(@q1, edit)
      assert_equal %w[2027-01-10 2027-03-31], period(@q1)
      redo_edit(@q1, edit)
      assert_equal %w[2027-01-10 2027-04-30], period(@q1)
    end

    should "undo through the rest of a split, and refuse through an alternative or another step" do
      edit = set(@q1, ends_on: "2027-02-28")
      lean = fork(@q1, relation: "instead", name: "Lean Q1")
      placed = 2.times.map do
        @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7, set_by_id: @editor_id,
                                                              end_state: { placements: [ { unit_id: SecureRandom.uuid_v7, allocation: 1.0 } ] })
        last_event.event_id
      end
      agreed = SecureRandom.uuid_v7
      @plan.split_scenario(@q1, agreed_id: agreed, name: "Agreed", event_ids: [ placed.first ], split_by_id: @editor_id)

      assert_equal "This scenario is an alternative: it takes its period from its parent", refusal { undo_edit(lean, edit) }
      assert_equal "This scenario has no such change", refusal { undo_edit(@q2, edit) }
      undo_edit(@q1, edit)
      assert_equal agreed, last_event.data[:scenario_id]
      assert_equal %w[2027-01-01 2027-03-31], period(agreed)
    end
  end

  context "a fork that closed a step" do
    setup do
      @open = fork(@q2, name: "Q3")
      @edit = set(@open, ends_on: nil).then { set(@open, ends_on: "2027-09-30") }
      @reopened = set(@open, ends_on: nil)
      @q4 = fork(@open, name: "Q4", starts_on: "2027-10-01")
      @fork = last_event.event_id
    end

    should "stand for good: an edit before it can't be undone, and the fork itself can't be" do
      assert_equal "The next step forked after this, closing these dates on 2027-09-30, so this can't be undone: set the dates directly instead",
                   refusal { undo_edit(@open, @reopened) }
      assert_equal "Forking the next step closed these dates, and undo doesn't reopen them: set the dates directly instead",
                   refusal { undo_edit(@open, @fork) }
      assert_equal %w[2027-07-01 2027-09-30], period(@open)
    end

    should "let an edit made after it be undone, back to the closing date" do
      later = set(@open, ends_on: "2027-08-31")
      assert_equal %w[2027-09-01], period(@q4).first(1)

      undo_edit(@open, later)
      assert_equal %w[2027-07-01 2027-09-30], period(@open)
      assert_equal %w[2027-10-01], period(@q4).first(1)
    end
  end

  context "Undo and Redo without an event id" do
    should "pick the person's latest, across changes and date edits" do
      @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7, set_by_id: @editor_id,
                                                            end_state: { placements: [ { unit_id: SecureRandom.uuid_v7, allocation: 1.0 } ] })
      change = last_event.event_id
      edit = set(@q1, ends_on: "2027-02-28")

      assert_equal edit, @plan.last_undoable_by(@q1, @editor_id)
      assert_nil @plan.last_undoable_by(@q1, @other_id)
      undo_edit(@q1, edit)
      assert_equal change, @plan.last_undoable_by(@q1, @editor_id)
      assert_equal edit, @plan.last_redoable_by(@q1, @editor_id)

      undo_edit(@q1, change)
      assert_equal change, @plan.last_redoable_by(@q1, @editor_id)
      redo_edit(@q1, change)
      assert_equal edit, @plan.last_redoable_by(@q1, @editor_id)
    end

    should "not take back a date edit while a later change of the person's stands, though a move put an older one last" do
      moved = SecureRandom.uuid_v7
      older = place(@q1, subject_id: moved)
      edit = set(@q2, ends_on: "2027-06-15")
      place(@q2)
      @plan.move_change(scenario_id: @q1, subject_id: moved, facet: "assignment", direction: "later", moved_by_id: @other_id)

      assert_equal older, @plan.last_undoable_by(@q2, @editor_id)
      refute_equal edit, @plan.last_undoable_by(@q2, @editor_id)
    end

    should "offer to redo the latest undo, though an earlier one was undone, redone and undone again" do
      @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7, set_by_id: @editor_id,
                                                            end_state: { placements: [ { unit_id: SecureRandom.uuid_v7, allocation: 1.0 } ] })
      change = last_event.event_id
      edit = set(@q1, ends_on: "2027-02-28")

      @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7, set_by_id: @editor_id,
                                                            end_state: { placements: [ { unit_id: SecureRandom.uuid_v7, allocation: 1.0 } ] })
      undo_edit(@q1, last_event.event_id)
      undo_edit(@q1, change)
      redo_edit(@q1, change)
      undo_edit(@q1, change)
      undo_edit(@q1, edit)
      assert_equal edit, @plan.last_redoable_by(@q1, @editor_id)
    end

    should "end what the person can redo once they make a change or a date edit, whichever they undid" do
      edit = set(@q1, ends_on: "2027-02-28")
      undo_edit(@q1, edit)
      @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7, set_by_id: @editor_id,
                                                            end_state: { placements: [ { unit_id: SecureRandom.uuid_v7, allocation: 1.0 } ] })
      assert_nil @plan.last_redoable_by(@q1, @editor_id)

      undo_edit(@q1, last_event.event_id)
      set(@q1, ends_on: "2027-03-15")
      assert_nil @plan.last_redoable_by(@q1, @editor_id)
    end

    should "end the redo of a change in the rest of a split once its dates are edited through it" do
      placed = 2.times.map { place(@q1) }
      @plan.split_scenario(@q1, agreed_id: SecureRandom.uuid_v7, name: "Agreed", event_ids: [ placed.first ], split_by_id: @editor_id)
      undo_edit(@q1, placed.last)
      assert_equal placed.last, @plan.last_redoable_by(@q1, @editor_id)

      set(@q1, ends_on: "2027-03-15")
      assert_nil @plan.last_redoable_by(@q1, @editor_id)
    end

    should "end the redo of a date edit once a change moves into its step" do
      subject_id = SecureRandom.uuid_v7
      place(@q2, subject_id:)
      undo_edit(@q1, set(@q1, ends_on: "2027-02-28"))
      assert_predicate @plan.last_redoable_by(@q1, @editor_id), :present?

      @plan.move_change(scenario_id: @q2, subject_id:, facet: "assignment", direction: "earlier", moved_by_id: @editor_id)
      assert_nil @plan.last_redoable_by(@q1, @editor_id)
    end

    should "not offer an edit someone else's later edit replaced, nor a redo once a new edit stands" do
      edit = set(@q1, ends_on: "2027-02-28")
      set(@q1, ends_on: "2027-02-15", by: @other_id)
      assert_nil @plan.last_undoable_by(@q1, @editor_id)

      undo_edit(@q1, last_event.event_id, by: @other_id)
      undo_edit(@q1, edit)
      set(@q1, ends_on: "2027-03-15", by: @other_id)
      assert_nil @plan.last_redoable_by(@q1, @editor_id)
    end
  end

  context "an archived plan" do
    should "refuse an undo and a redo of a date edit" do
      edit = set(@q1, ends_on: "2027-02-28")
      @plan.archive(archived_by_id: @editor_id, archived_on: Date.new(2026, 11, 16), time_zone: "UTC")

      assert_equal TeamPlanning::PlanAggregate::ARCHIVED, refusal { undo_edit(@q1, edit) }
      assert_equal TeamPlanning::PlanAggregate::ARCHIVED, refusal { redo_edit(@q1, edit) }
    end
  end
end
