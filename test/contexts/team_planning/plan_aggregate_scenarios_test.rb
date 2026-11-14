# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateScenariosTest < ActiveSupport::TestCase
  setup do
    @plan_id = SecureRandom.uuid_v7
    @editor_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @editor_id)
  end

  def fork(parent_id = @plan_id, relation: "then", name: "Q1", ends_on: nil, starts_on: nil)
    id = SecureRandom.uuid_v7
    @plan.fork_scenario(id, parent_id:, relation:, name:, ends_on:, starts_on:, forked_by_id: @editor_id)
    id
  end

  def period(id) = @plan.period_of(id).then { [ it.begin.iso8601, it.end.iso8601 ] }

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  def last_event = @plan.unpublished_events.to_a.last

  context "#fork_scenario" do
    should "start the first step on the base date, and record who forked it" do
      q1 = fork(name: "  Q1   plan ", ends_on: "2027-03-31")

      assert_kind_of TeamPlanning::Events::ScenarioForked, last_event
      assert_equal({ plan_id: @plan_id, scenario_id: q1, parent_id: @plan_id, relation: "then", name: "Q1 plan",
                     starts_on: "2027-01-01", ends_on: "2027-03-31", forked_by_id: @editor_id }, last_event.data)
      assert_equal %w[2027-01-01 2027-03-31], period(q1)
    end

    should "start a step the day after its parent ends" do
      q1 = fork(ends_on: "2027-03-31")
      q2 = fork(q1, name: "Q2", ends_on: "2027-06-30", starts_on: "2027-04-01")
      assert_equal %w[2027-04-01 2027-06-30], period(q2)
    end

    should "give an alternative its parent's period, and an alternative of an alternative the original's" do
      q1 = fork(ends_on: "2027-03-31")
      lean = fork(q1, relation: "instead", name: "Lean Q1")
      leaner = fork(lean, relation: "instead", name: "Leaner Q1", starts_on: "2027-01-01", ends_on: "2027-03-31")

      assert_equal period(q1), period(lean)
      assert_equal period(q1), period(leaner)
      assert_equal({ starts_on: "2027-01-01", ends_on: "2027-03-31" }, last_event.data.slice(:starts_on, :ends_on))
    end

    should "refuse a period that doesn't fit the tree" do
      q1 = fork(ends_on: "2027-03-31")

      assert_equal "A step after Q1 starts on 2027-04-01, the day it begins",
                   refusal { fork(q1, name: "Q2", starts_on: "2027-04-02", ends_on: "2027-06-30") }
      assert_equal "Say when this step ends", refusal { fork(q1, name: "Q2") }
      assert_equal "This step would end on 2027-03-30, before it starts on 2027-04-01",
                   refusal { fork(q1, name: "Q2", ends_on: "2027-03-30") }
      assert_equal "An alternative covers Q1's period, 2027-01-01 to 2027-03-31",
                   refusal { fork(q1, relation: "instead", ends_on: "2027-04-30") }
      assert_equal "An alternative covers Q1's period, 2027-01-01 to 2027-03-31",
                   refusal { fork(q1, relation: "instead", starts_on: "2027-01-02") }
    end

    should "let a step have one next step, so its alternatives are alternatives" do
      q1 = fork(ends_on: "2027-03-31")
      fork(q1, name: "Q2", ends_on: "2027-06-30")

      assert_equal "Q2 already follows Q1: fork an alternative to it instead",
                   refusal { fork(q1, name: "Other Q2", ends_on: "2027-06-30") }
      assert_equal "Q1 already follows the baseline: fork an alternative to it instead",
                   refusal { fork(name: "Other Q1", ends_on: "2027-03-31") }
    end

    should "refuse an alternative to the baseline" do
      assert_equal "The baseline has no alternative: fork a step after it instead", refusal { fork(relation: "instead") }
    end

    should "refuse a taken id, an unknown parent, an unknown relation and a bad name" do
      q1 = fork(ends_on: "2027-03-31")
      taken = ->(id) { @plan.fork_scenario(id, parent_id: q1, relation: "instead", name: "X", forked_by_id: @editor_id) }

      assert_equal "This plan already has that scenario", refusal { taken.call(q1) }
      assert_equal "This plan already has that scenario", refusal { taken.call(@plan_id) }
      assert_equal "This plan has no such scenario", refusal { fork(SecureRandom.uuid_v7, relation: "instead") }
      assert_equal "A scenario forks as then or instead", refusal { fork(q1, relation: "after") }
      assert_equal "A scenario needs a name", refusal { fork(q1, relation: "instead", name: " ") }
      assert_equal "A scenario's name can be at most 120 characters", refusal { fork(q1, relation: "instead", name: "x" * 121) }
      assert_raises(Date::Error) { fork(q1, name: "Q2", ends_on: "next June") }
    end

    should "refuse once the plan is deleted" do
      @plan.delete(deleted_by_id: @editor_id)
      assert_equal "Next year has been deleted", refusal { fork(ends_on: "2027-03-31") }
    end
  end

  context "#set_scenario_period" do
    setup do
      @q1 = fork(ends_on: "2027-03-31")
      @lean = fork(@q1, relation: "instead", name: "Lean Q1")
      @q2 = fork(@q1, name: "Q2", ends_on: "2027-06-30")
      @lean_q2 = fork(@lean, name: "Lean Q2", ends_on: "2027-05-31")
    end

    should "move the end, and start every step after it from the new end" do
      @plan.set_scenario_period(@q1, ends_on: "2027-02-28", set_by_id: @editor_id)

      assert_kind_of TeamPlanning::Events::ScenarioPeriodSet, last_event
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: "2027-02-28",
                     previous_ends_on: "2027-03-31", set_by_id: @editor_id }, last_event.data)
      assert_equal %w[2027-01-01 2027-02-28], period(@lean)
      assert_equal %w[2027-03-01 2027-06-30], period(@q2)
      assert_equal %w[2027-03-01 2027-05-31], period(@lean_q2)
    end

    should "keep every path contiguous after each move" do
      @plan.set_scenario_period(@q1, ends_on: "2027-04-15", set_by_id: @editor_id)
      @plan.set_scenario_period(@q2, ends_on: "2027-09-30", set_by_id: @editor_id)

      [ [ @q1, @q2 ], [ @lean, @lean_q2 ] ].each do |first, second|
        assert_equal @plan.period_of(first).end + 1, @plan.period_of(second).begin
      end
      assert_equal Date.new(2027, 1, 1), @plan.period_of(@q1).begin
    end

    should "refuse a move that leaves a later step ending before it starts, naming it" do
      assert_equal "Lean Q2 would end on 2027-05-31, before it starts on 2027-06-01",
                   refusal { @plan.set_scenario_period(@q1, ends_on: "2027-05-31", set_by_id: @editor_id) }
      assert_equal "Q2 would end on 2027-06-30, before it starts on 2027-07-01",
                   refusal { @plan.set_scenario_period(@q1, ends_on: "2027-06-30", set_by_id: @editor_id) }
      assert_equal "Q1 would end on 2026-12-31, before it starts on 2027-01-01",
                   refusal { @plan.set_scenario_period(@q1, ends_on: "2026-12-31", set_by_id: @editor_id) }
      assert_equal %w[2027-01-01 2027-03-31], period(@q1)
    end

    should "write nothing for the same end" do
      before = @plan.unpublished_events.count
      @plan.set_scenario_period(@q1, ends_on: Date.new(2027, 3, 31), set_by_id: @editor_id)
      assert_equal before, @plan.unpublished_events.count
    end

    should "refuse the baseline, an alternative and an unknown scenario" do
      assert_equal "The baseline stands on the base date and has no period",
                   refusal { @plan.set_scenario_period(@plan_id, ends_on: "2027-03-31", set_by_id: @editor_id) }
      assert_equal "Lean Q1 is an alternative: it takes its period from Q1",
                   refusal { @plan.set_scenario_period(@lean, ends_on: "2027-03-31", set_by_id: @editor_id) }
      assert_equal "This plan has no such scenario",
                   refusal { @plan.set_scenario_period(SecureRandom.uuid_v7, ends_on: "2027-03-31", set_by_id: @editor_id) }
    end
  end

  context "#remove_scenario" do
    setup do
      @q1 = fork(ends_on: "2027-03-31")
      @lean = fork(@q1, relation: "instead", name: "Lean Q1")
      @q2 = fork(@q1, name: "Q2", ends_on: "2027-06-30")
    end

    should "refuse a scenario others fork from, saying how many" do
      assert_equal "2 scenarios fork from Q1: remove them first", refusal { @plan.remove_scenario(@q1, removed_by_id: @editor_id) }
    end

    should "remove a leaf, and never reuse its id" do
      @plan.remove_scenario(@q2, removed_by_id: @editor_id)

      assert_equal({ plan_id: @plan_id, scenario_id: @q2, removed_by_id: @editor_id }, last_event.data)
      assert_not @plan.scenario?(@q2)
      assert_equal "1 scenario forks from Q1: remove it first", refusal { @plan.remove_scenario(@q1, removed_by_id: @editor_id) }
      assert_equal "This plan already has that scenario",
                   refusal { @plan.fork_scenario(@q2, parent_id: @q1, relation: "instead", name: "Again", forked_by_id: @editor_id) }
      assert_equal "This plan has no such scenario", refusal { @plan.remove_scenario(@q2, removed_by_id: @editor_id) }
      fork(@q1, name: "New Q2", ends_on: "2027-06-30")
    end

    should "refuse the baseline" do
      assert_equal "The baseline can't be removed", refusal { @plan.remove_scenario(@plan_id, removed_by_id: @editor_id) }
    end
  end

  should "rebuild the same tree from its events" do
    q1 = fork(ends_on: "2027-03-31")
    lean = fork(q1, relation: "instead", name: "Lean Q1")
    q2 = fork(q1, name: "Q2", ends_on: "2027-06-30")
    @plan.set_scenario_period(q1, ends_on: "2027-02-28", set_by_id: @editor_id)
    @plan.remove_scenario(q2, removed_by_id: @editor_id)

    replayed = TeamPlanning::PlanAggregate.new
    @plan.unpublished_events.each { replayed.apply(it) }

    assert_equal @plan.scenarios, replayed.scenarios
    assert_equal @plan.period_of(lean), replayed.period_of(lean)
    assert_equal "This plan already has that scenario",
                 assert_raises(TeamPlanning::Error) { replayed.fork_scenario(q2, parent_id: q1, relation: "instead", name: "X", forked_by_id: @editor_id) }.message
  end
end
