# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateCloseTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.end_state(end_state) = end_state.slice(:title)
    def self.apply_to(map, _data) = map
  end

  AFTER_Q1 = Date.new(2027, 4, 1)
  AFTER_Q2 = Date.new(2027, 7, 1)

  setup do
    @plan_id = SecureRandom.uuid_v7
    @editor_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @editor_id, time_zone: "UTC")
    @q1 = fork(@plan_id, ends_on: "2027-03-31")
    @lean = fork(@q1, relation: "instead")
    @q2 = fork(@q1, ends_on: "2027-06-30")
    @lean_q2 = fork(@lean, ends_on: "2027-06-30")
  end

  def fork(parent_id, relation: "then", ends_on: nil)
    SecureRandom.uuid_v7.tap { @plan.fork_scenario(it, parent_id:, relation:, name: "Step", ends_on:, forked_by_id: @editor_id) }
  end

  def close(scenario_id, today: AFTER_Q2) = @plan.close_step(scenario_id, today:, closed_by_id: @editor_id)

  def set(scenario_id) = @plan.set_change(TitleSet, scenario_id:, subject_id: "ada", set_by_id: @editor_id, end_state: { title: "Lead" })

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  def last_event = @plan.unpublished_events.to_a.last

  def replayed = TeamPlanning::PlanAggregate.new.tap { |plan| @plan.unpublished_events.each { plan.apply(it) } }

  context "#close_step" do
    should "record the step's last day, the plan's base and who closed it" do
      close(@q1, today: AFTER_Q1)

      assert_kind_of TeamPlanning::Events::StepClosed, last_event
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, ends_on: "2027-03-31", base_on: "2027-01-01", closed_by_id: @editor_id },
                   last_event.data)
      assert_equal [ [ @q1, Date.new(2027, 3, 31) ] ], replayed.closed_steps
    end

    should "refuse a step whose period hasn't ended" do
      assert_equal "This step ends on 2027-03-31: it can be closed from the day after", refusal { close(@q1, today: Date.new(2027, 3, 31)) }
    end

    should "refuse a step with no end date" do
      @plan.set_scenario_period(@q2, ends_on: nil, set_by_id: @editor_id)
      close(@q1)

      assert_equal "A step with no end date can't be closed: give it an end date first", refusal { close(@q2) }
    end

    should "close steps in timeline order" do
      assert_equal "Close the step before this one first", refusal { close(@q2) }
      assert_equal "The baseline can't be closed", refusal { close(@plan_id) }
    end

    should "close an alternative as the step taken, leaving the original not taken" do
      close(@lean)

      assert @plan.frozen?(@q1)
      assert_equal "This step is closed: reopen it to change it", refusal { set(@q1) }
      assert_equal "This scenario wasn't taken: another step closed in its place", refusal { close(@q2) }
      close(@lean_q2)
      assert_equal [ @lean, @lean_q2 ], @plan.closed_steps.map(&:first)
    end

    should "say which closed step a scenario closed as, following a split's agreed part and nothing passed over" do
      agreed = SecureRandom.uuid_v7
      set(@q1)
      @plan.set_change(TitleSet, scenario_id: @q1, subject_id: "brook", set_by_id: @editor_id, end_state: { title: "Lead" })
      moving = @plan.changes_in(@q1).find { it.data[:subject_id] == "brook" }.event_id
      @plan.split_scenario(@q1, agreed_id: agreed, name: "Agreed", event_ids: [ moving ], split_by_id: @editor_id)
      close(@q1)

      assert_equal [ @q1, @q1, nil, nil ], [ @q1, agreed, @lean, @plan_id ].map { @plan.closed_as(it) }
      close(@q2)
      assert_equal [ @q1, @q2 ], [ @q1, @q2 ].map { @plan.closed_as(it) }
    end

    should "refuse a closed step and an archived plan" do
      close(@q1)
      assert_equal "This step is closed: reopen it to change it", refusal { close(@q1) }

      @plan.archive(archived_by_id: @editor_id, archived_on: Date.new(2027, 4, 2), time_zone: "UTC")
      assert_equal TeamPlanning::PlanAggregate::ARCHIVED, refusal { close(@q2) }
    end

    should "say why a step can't close, without closing it" do
      assert_equal "Close the step before this one first", @plan.not_closable_because(@q2, AFTER_Q2)
      assert_nil @plan.not_closable_because(@q1, AFTER_Q2)
      assert_empty @plan.closed_steps
    end
  end

  context "once a step is closed" do
    setup { close(@q1) }

    should "stand the steps after it on the day after it ends, and leave the rest on the base" do
      assert_equal [ @q1, Date.new(2027, 3, 31) ], @plan.standing_after(@q2)
      assert_nil @plan.standing_after(@q1)
      assert_nil @plan.standing_after(@lean)
      assert_nil @plan.standing_after(@plan_id)
    end

    should "keep a step closed after it standing where it stood while open, and the next on that one" do
      q3 = fork(@q2, ends_on: "2027-09-30")
      lean_q2 = fork(@q2, relation: "instead")
      close(@q2, today: Date.new(2027, 10, 1))

      assert_equal [ @q1, Date.new(2027, 3, 31) ], @plan.standing_after(@q2)
      assert_equal [ @q1, Date.new(2027, 3, 31) ], @plan.standing_after(lean_q2)
      assert_equal [ @q2, Date.new(2027, 6, 30) ], @plan.standing_after(q3)
      assert_nil @plan.standing_after(@lean_q2)
    end

    should "refuse every change to the closed step and the alternatives not taken" do
      assert_equal "This step is closed: reopen it to change it", refusal { set(@q1) }
      assert_equal "This scenario wasn't taken: another step closed in its place", refusal { set(@lean) }
      assert_equal "This scenario wasn't taken: another step closed in its place", refusal { set(@lean_q2) }
      assert_equal "This step is closed: reopen it to change it", refusal { @plan.set_scenario_period(@q1, ends_on: "2027-04-30", set_by_id: @editor_id) }
      assert_equal "This scenario wasn't taken: another step closed in its place", refusal { @plan.remove_scenario(@lean_q2, removed_by_id: @editor_id) }
      assert_equal "A scenario can't fork there: a step closed on the timeline in its place", refusal { fork(@q1, relation: "instead") }
      assert_equal "A scenario can't fork there: a step closed on the timeline in its place", refusal { fork(@lean_q2) }
    end

    should "keep the next step, its alternatives and the root open" do
      set(@q2)
      set(@plan_id)
      fork(@q2, relation: "instead")
      fork(@q2, ends_on: "2027-09-30")
      @plan.rename_scenario(@q1, name: "Q1 as it went", current: "Step", renamed_by_id: @editor_id)

      assert_equal 2, @plan.changes_in(@q2).size + @plan.changes_in(@plan_id).size
      assert_kind_of TeamPlanning::Events::ScenarioRenamed, last_event
    end

    should "let a closed step's name and description change, and nothing else" do
      @plan.rename_scenario(@q1, name: "Q1 as it went", current: "Step", renamed_by_id: @editor_id)
      @plan.describe_scenario(@q1, description: "Hired two", described_by_id: @editor_id)

      assert_equal "This step is closed: reopen it to change it", refusal { set(@q1) }
      assert_equal "This step is closed: reopen it to change it", refusal { @plan.set_scenario_period(@q1, ends_on: "2027-04-30", set_by_id: @editor_id) }
    end

    should "refuse moving a change into the closed step" do
      @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q2, subject_id: "ada", set_by_id: @editor_id,
                                                            end_state: { placements: [ { unit_id: "sales", allocation: 1.0 } ] })
      assert_equal "This step is closed: reopen it to change it",
                   refusal { @plan.move_change(scenario_id: @q2, subject_id: "ada", facet: "assignment", direction: "earlier", moved_by_id: @editor_id) }
    end

    should "refuse undoing or redoing a move that would put a change back into the closed step or take one out" do
      @plan.reopen_step(@q1, reopened_by_id: @editor_id)
      @plan.set_change(TeamPlanning::Events::AssignmentSet, scenario_id: @q1, subject_id: "ada", set_by_id: @editor_id,
                                                            end_state: { placements: [ { unit_id: "sales", allocation: 1.0 } ] })
      @plan.move_change(scenario_id: @q1, subject_id: "ada", facet: "assignment", direction: "later", moved_by_id: @editor_id)
      moved = last_event.event_id
      close(@q1)
      assert_equal "This step is closed: reopen it to change it",
                   refusal { @plan.undo_change(scenario_id: @q2, event_id: moved, undone_by_id: @editor_id) }

      @plan.reopen_step(@q1, reopened_by_id: @editor_id)
      @plan.undo_change(scenario_id: @q2, event_id: moved, undone_by_id: @editor_id)
      close(@q1)
      assert_equal "This step is closed: reopen it to change it",
                   refusal { @plan.redo_change(scenario_id: @q2, event_id: moved, redone_by_id: @editor_id) }
    end

    should "refuse updating the plan to today" do
      assert_equal TeamPlanning::PlanAggregate::CLOSED_REBASE,
                   refusal { @plan.rebase(base_on: "2027-02-01", expected_base_on: "2027-01-01", conflicts: [], rebased_by_id: @editor_id, time_zone: "UTC") }
    end
  end

  context "#reopen_step" do
    should "reopen the last step closed, so the plan stands as before" do
      close(@q1)
      close(@q2)

      assert_equal "Only the last step closed can be reopened: reopen the steps after it first",
                   refusal { @plan.reopen_step(@q1, reopened_by_id: @editor_id) }
      @plan.reopen_step(@q2, reopened_by_id: @editor_id)
      assert_equal({ plan_id: @plan_id, scenario_id: @q2, reopened_by_id: @editor_id }, last_event.data)
      @plan.reopen_step(@q1, reopened_by_id: @editor_id)

      plan = replayed
      assert_empty plan.closed_steps
      assert_not plan.frozen?(@lean)
      assert_nil plan.standing_after(@q2)
      set(@lean)
    end

    should "refuse a step that isn't closed" do
      assert_equal "This step isn't closed", refusal { @plan.reopen_step(@q1, reopened_by_id: @editor_id) }
    end
  end
end
