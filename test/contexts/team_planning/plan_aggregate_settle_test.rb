# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateSettleTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
  end

  KEY = %w[lin title].freeze

  setup do
    @plan_id = SecureRandom.uuid_v7
    @ada_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @ada_id)
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @lean = fork(@q1, "instead")
    @bold = fork(@q1, "instead")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: relation, ends_on:, forked_by_id: @ada_id)
    end
  end

  def last_event = @plan.unpublished_events.to_a.last

  def set(scenario_id, title) = @plan.set_change(TitleSet, scenario_id:, subject_id: "lin", set_by_id: @ada_id, end_state: { title: })

  def winning(scenario_id) = @plan.winning_changes(scenario_id)[KEY]

  def carry(*scenario_ids, on: "2027-02-01")
    conflicts = scenario_ids.map { { scenario_id: it, subject_id: "lin", facet: "title", change_id: winning(it).event_id } }
    @plan.rebase(base_on: on, expected_base_on: @plan.base_on, conflicts:, rebased_by_id: @ada_id)
  end

  def settle(scenario_id, choice, title, pinned_from: nil, note: nil)
    @plan.settle_conflict(TitleSet, scenario_id:, subject_id: "lin", facet: "title", choice:, end_state: { title: },
                                    settled_by_id: @ada_id, pinned_from:, note:)
  end

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "keep a scenario's own change by setting it again, marked as settling the conflict" do
    set(@q1, "Staff")
    carry(@q1)
    settle(@q1, "plan", "Staff", note: "Promised in March")

    assert_kind_of TitleSet, last_event
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, subject_id: "lin", title: "Staff", set_by_id: @ada_id,
                   settles: { since: "2027-02-01", choice: "plan" } }, last_event.data.except(:note))
    assert_kind_of Shreddable::Value, last_event.data[:note]
  end

  # The values match before and after, so only the rule can end it: the update saw another change.
  should "end the conflict by the rule that a newer change settles it, though the end state is the same" do
    set(@q1, "Staff")
    carry(@q1)
    settle(@q1, "plan", "Staff")

    assert_equal({ title: "Staff" }, winning(@q1).data.slice(:title))
    assert_empty @plan.carried_conflicts(@q1)

    @plan.undo_change(scenario_id: @q1, event_id: last_event.event_id, undone_by_id: @ada_id)
    assert_equal({ KEY => Date.new(2027, 2, 1) }, @plan.carried_conflicts(@q1))
  end

  should "keep an inherited change with a pin that names where it came from" do
    set(@q1, "Staff")
    carry(@lean)
    settle(@lean, "plan", "Staff", pinned_from: [ @q1, winning(@q1).event_id ])

    assert_kind_of TeamPlanning::Events::ChangePinned, last_event
    assert_equal({ scenario_id: @lean, pinned_from_scenario_id: @q1, pinned_from_event_id: winning(@q1).event_id,
                   settles: { since: "2027-02-01", choice: "plan" } },
                 last_event.data.slice(:scenario_id, :pinned_from_scenario_id, :pinned_from_event_id, :settles))
    assert_empty @plan.carried_conflicts(@lean)
  end

  should "keep a scenario's own pin as a pin, still naming the change the first pin kept" do
    set(@q1, "Staff")
    kept = [ @q1, winning(@q1).event_id ]
    @plan.pin_change(TitleSet, scenario_id: @lean, subject_id: "lin", facet: "title", end_state: { title: "Staff" },
                               pinned_by_id: @ada_id, pinned_from: kept)
    carry(@lean)
    settle(@lean, "plan", "Staff", pinned_from: [ @q1, winning(@lean).event_id ])

    assert_kind_of TeamPlanning::Events::ChangePinned, last_event
    assert_equal kept, last_event.data.values_at(:pinned_from_scenario_id, :pinned_from_event_id)
    assert_equal({ since: "2027-02-01", choice: "plan" }, last_event.data[:settles])
    assert_empty @plan.carried_conflicts(@lean)
  end

  should "keep a scenario's own pin of the baseline as a pin of the baseline" do
    @plan.pin_change(TitleSet, scenario_id: @q1, subject_id: "lin", facet: "title", end_state: { title: "Staff" }, pinned_by_id: @ada_id)
    carry(@q1)
    settle(@q1, "plan", "Staff")

    assert_kind_of TeamPlanning::Events::ChangePinned, last_event
    assert_equal [ nil, nil ], last_event.data.values_at(:pinned_from_scenario_id, :pinned_from_event_id)
  end

  should "follow reality in the scenario alone, leaving the one that made the change and its siblings as they were" do
    set(@q1, "Staff")
    carry(@lean, @bold)
    made = winning(@q1)
    settle(@lean, "reality", "Senior")

    assert_equal({ scenario_id: @lean, title: "Senior", settles: { since: "2027-02-01", choice: "reality" } },
                 last_event.data.slice(:scenario_id, :title, :settles))
    assert_equal made, winning(@q1)
    assert_equal made, winning(@bold)
    assert_equal [ KEY ], @plan.carried_conflicts(@bold).keys
    assert_empty @plan.carried_conflicts(@lean)
  end

  should "refuse a conflict no update carried, and a choice it doesn't know" do
    set(@q1, "Staff")
    assert_equal "No update to today carried a conflict here forward, so there is nothing to settle: update the plan to today first",
                 refusal { settle(@q1, "plan", "Staff") }

    carry(@q1)
    assert_equal "A conflict is settled by keeping the plan or following reality", refusal { settle(@q1, "ignore", "Staff") }
    set(@q1, "Principal")
    assert_match(/nothing to settle/, refusal { settle(@q1, "plan", "Principal") })
  end

  should "replay a settle from the stream, its marker stored with string keys" do
    set(@q1, "Staff")
    carry(@q1)
    settle(@q1, "plan", "Staff")
    replayed = TeamPlanning::PlanAggregate.new
    @plan.unpublished_events.each do |event|
      data = event.data.deep_stringify_keys.deep_symbolize_keys
      replayed.apply(event.class.new(event_id: event.event_id, data: data[:settles] ? data.merge(settles: data[:settles].stringify_keys) : data))
    end

    assert_empty replayed.carried_conflicts(@q1)
  end
end
