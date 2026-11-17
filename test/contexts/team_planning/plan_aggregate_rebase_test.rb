# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateRebaseTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
  end

  setup do
    @plan_id = SecureRandom.uuid_v7
    @ada_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @ada_id, time_zone: "UTC")
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @lean = fork(@q1, "instead")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: relation == "then" ? "Q1" : "Lean Q1", ends_on:, forked_by_id: @ada_id)
    end
  end

  def last_event = @plan.unpublished_events.to_a.last

  def set(scenario_id, title) = @plan.set_change(TitleSet, scenario_id:, subject_id: "lin", set_by_id: @ada_id, end_state: { title: })

  def rebase(base_on, expected: @plan.base_on, conflicts: [])
    @plan.rebase(base_on:, expected_base_on: expected, conflicts:, rebased_by_id: @ada_id, time_zone: "UTC")
  end

  def conflict(scenario_id, change_id: @plan.winning_changes(scenario_id)[%w[lin title]]&.event_id || "none")
    { scenario_id:, subject_id: "lin", facet: "title", change_id: }
  end

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "move the base, record the old one and the conflicts, and start the first step on it" do
    set(@q1, "Staff")
    rebase("2027-02-10", conflicts: [ conflict(@q1), conflict(@q1) ])

    assert_kind_of TeamPlanning::Events::PlanRebased, last_event
    assert_equal({ plan_id: @plan_id, base_on: "2027-02-10", previous_base_on: "2027-01-01",
                   conflicts: [ conflict(@q1) ], rebased_by_id: @ada_id, time_zone: "UTC" }, last_event.data)
    assert_equal Date.new(2027, 2, 10), @plan.base_on
    assert_equal Date.new(2027, 2, 10)..Date.new(2027, 3, 31), @plan.period_of(@lean)
  end

  should "refuse a base that doesn't move forward, a stale read, and one past the first step's end" do
    assert_equal "This plan already stands on 2027-01-01", refusal { rebase("2027-01-01") }
    assert_equal "This plan stands on 2027-01-01, after 2026-12-31: a base only moves forward", refusal { rebase("2026-12-31") }
    assert_equal "This plan has moved since you looked: it now stands on 2027-01-01",
                 refusal { rebase("2027-02-01", expected: "2026-12-01") }
    assert_equal "The first step ends on 2027-03-31, before 2027-04-01: end it later or remove it first", refusal { rebase("2027-04-01") }
    assert_equal "This plan has no such scenario", refusal { rebase("2027-02-01", conflicts: [ conflict(SecureRandom.uuid_v7, change_id: "e") ]) }
    assert_equal "A conflict needs a scenario_id, subject_id, facet and change_id",
                 refusal { rebase("2027-02-01", conflicts: [ conflict(@q1, change_id: "e").except(:change_id) ]) }
  end

  should "carry a conflict until a set, clear or undo ends it, keeping the date it was first found" do
    set(@q1, "Staff")
    rebase("2027-02-01", conflicts: [ conflict(@q1) ])
    rebase("2027-03-01", conflicts: [ conflict(@q1) ])
    assert_equal({ %w[lin title] => Date.new(2027, 2, 1) }, @plan.carried_conflicts(@q1))
    assert_empty @plan.carried_conflicts(@lean)

    @plan.undo_change(scenario_id: @q1, event_id: @plan.log_of(@q1).last.event_id, undone_by_id: @ada_id)
    assert_empty @plan.carried_conflicts(@q1)
    @plan.redo_change(scenario_id: @q1, event_id: @plan.log_of(@q1).last.event_id, redone_by_id: @ada_id)
    assert_equal [ %w[lin title] ], @plan.carried_conflicts(@q1).keys

    set(@q1, "Principal")
    assert_empty @plan.carried_conflicts(@q1)
  end

  should "end a carried conflict with a clear, and drop one the next update no longer finds" do
    set(@q1, "Staff")
    rebase("2027-02-01", conflicts: [ conflict(@q1) ])
    @plan.clear_change(scenario_id: @q1, subject_id: "lin", facet: "title", cleared_by_id: @ada_id)
    assert_empty @plan.carried_conflicts(@q1)

    set(@q1, "Staff")
    rebase("2027-02-02", conflicts: [ conflict(@q1) ])
    rebase("2027-02-03")
    assert_empty @plan.carried_conflicts(@q1)
  end

  should "replay a rebase from the stream, conflict keys stored as strings" do
    set(@q1, "Staff")
    rebase("2027-02-01", conflicts: [ conflict(@q1) ])
    replayed = TeamPlanning::PlanAggregate.new
    @plan.unpublished_events.each do |event|
      data = event.data.deep_stringify_keys.deep_symbolize_keys
      data[:conflicts] = data[:conflicts].map(&:stringify_keys) if data[:conflicts]
      replayed.apply(event.class.new(event_id: event.event_id, data:))
    end

    assert_equal Date.new(2027, 2, 1), replayed.base_on
    assert_equal({ %w[lin title] => Date.new(2027, 2, 1) }, replayed.carried_conflicts(@q1))
  end
end
