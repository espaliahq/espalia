# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateOverridesTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
  end

  class TitleDropped < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.end_state(_end_state) = {}
    def self.apply_to(map, _data) = map
  end

  setup do
    @plan_id = SecureRandom.uuid_v7
    @editor_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @editor_id, time_zone: "UTC")
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @lean = fork(@q1, "instead")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: "Lean", ends_on:, forked_by_id: @editor_id)
    end
  end

  def set(scenario_id, title, subject_id: "ada") = @plan.set_change(TitleSet, scenario_id:, subject_id:, set_by_id: @editor_id, end_state: { title: })

  def clear(scenario_id, subject_id: "ada", facet: "title") = @plan.clear_change(scenario_id:, subject_id:, facet:, cleared_by_id: @editor_id)

  def pin(scenario_id, title, from: nil)
    @plan.pin_change(TitleSet, scenario_id:, subject_id: "ada", facet: "title", end_state: { title: }, pinned_by_id: @editor_id, pinned_from: from)
  end

  def inherited_title(scenario_id) = @plan.inherited_change(scenario_id, %w[ada title])&.last&.data&.dig(:title)

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "hand a facet back to the parent on a clear, keeping the cleared change in the stream" do
    set(@q1, "Senior Engineer")
    set(@lean, "Lead Engineer")
    set(@lean, "Lead Engineer", subject_id: "grace")
    clear(@lean)

    assert_equal [ "grace" ], @plan.changes_in(@lean).map { it.data[:subject_id] }
    assert_equal "Senior Engineer", inherited_title(@lean)
    assert_equal({ plan_id: @plan_id, scenario_id: @lean, subject_id: "ada", facet: "title", cleared_by_id: @editor_id },
                 @plan.unpublished_events.to_a.last.data)
    assert_equal 1, @plan.unpublished_events.count { it.is_a?(TitleSet) && it.data[:scenario_id] == @lean && it.data[:subject_id] == "ada" }
  end

  should "keep every change, pin and clear in the scenario's log, in order, and set again after a clear" do
    set(@q1, "Senior Engineer")
    set(@lean, "Lead Engineer")
    clear(@lean)
    pin(@lean, "Senior Engineer", from: [ @q1, @plan.changes_in(@q1).last.event_id ])
    clear(@lean)
    set(@lean, "Staff Engineer")

    assert_equal [ TitleSet, TeamPlanning::Events::ChangeCleared, TitleSet, TeamPlanning::Events::ChangeCleared, TitleSet ],
                 @plan.log_of(@lean).map(&:class)
    assert_equal [ "Staff Engineer" ], @plan.changes_in(@lean).map { it.data[:title] }
  end

  should "refuse a pin whose end state sets the plan, the scenario or who set it" do
    %i[plan_id scenario_id set_by_id].each do |field|
      error = assert_raises(ArgumentError) do
        @plan.pin_change(TitleSet, scenario_id: @lean, subject_id: "ada", facet: "title", end_state: { title: "x", field => @q1 },
                                   pinned_by_id: @editor_id)
      end
      assert_equal "An end state can't set #{field}", error.message
    end
  end

  should "refuse to clear a facet the scenario doesn't change, even when its parent does" do
    set(@q1, "Senior Engineer")

    assert_equal "This scenario doesn't change this, so there is nothing to clear", refusal { clear(@lean) }
    assert_equal "This plan has no such scenario", refusal { clear(SecureRandom.uuid_v7) }
  end

  should "find what a scenario inherits along its parent's chain, nearest first" do
    assert_nil @plan.inherited_change(@lean, %w[ada title])
    set(@plan_id, "Engineer")
    assert_equal "Engineer", inherited_title(@lean)

    set(@q1, "Senior Engineer")
    assert_equal [ @q1, "Senior Engineer" ], @plan.inherited_change(@lean, %w[ada title]).then { [ it.first, it.last.data[:title] ] }
    assert_nil @plan.inherited_change(@plan_id, %w[ada title])
  end

  should "pin as the scenario's own change, so a later change in the parent doesn't reach it" do
    set(@q1, "Senior Engineer")
    from = [ @q1, @plan.changes_in(@q1).last.event_id ]
    pin(@lean, "Senior Engineer", from:)
    set(@q1, "Staff Engineer")

    pinned = @plan.changes_in(@lean).sole
    assert_equal [ TitleSet, "Senior Engineer", %w[ada title] ], [ pinned.class, pinned.data[:title], pinned.key ]
    assert_equal({ plan_id: @plan_id, scenario_id: @lean, subject_id: "ada", facet: "title", kind: TitleSet.name,
                   end_state: { title: "Senior Engineer" }, pinned_from_scenario_id: @q1, pinned_from_event_id: from.last,
                   pinned_by_id: @editor_id }, @plan.unpublished_events.find { it.is_a?(TeamPlanning::Events::ChangePinned) }.data)
  end

  should "let a pin be cleared, and the scenario follow its parent again" do
    pin(@lean, "Engineer")
    clear(@lean)

    assert_empty @plan.changes_in(@lean)
  end

  should "refuse to pin the baseline, a facet the scenario already changes, or an end state that makes another key" do
    set(@lean, "Lead Engineer")

    assert_equal "The baseline inherits nothing to pin", refusal { pin(@plan_id, "Engineer") }
    assert_equal "This scenario already changes this: clear it to follow its parent, or set it", refusal { pin(@lean, "Engineer") }
    assert_raises(ArgumentError) do
      @plan.pin_change(TitleSet, scenario_id: @q1, subject_id: "ada", facet: "level", end_state: { title: "x" }, pinned_by_id: @editor_id)
    end
    assert_raises(ArgumentError) do
      @plan.pin_change(TeamPlanning::Events::ScenarioRemoved, scenario_id: @q1, subject_id: "ada", facet: "title", end_state: {}, pinned_by_id: @editor_id)
    end
  end

  should "clear and pin a facet two kinds share, whichever kind set it last" do
    set(@q1, "Senior Engineer")
    @plan.set_change(TitleDropped, scenario_id: @q1, subject_id: "ada", set_by_id: @editor_id)
    set(@lean, "Lead Engineer")
    @plan.set_change(TitleDropped, scenario_id: @lean, subject_id: "ada", set_by_id: @editor_id)

    assert_equal [ TitleSet, TitleDropped ], @plan.changes_in(@lean).map(&:class)
    clear(@lean)
    assert_empty @plan.changes_in(@lean)

    _, inherited = @plan.inherited_change(@lean, %w[ada title])
    @plan.pin_change(inherited.class, scenario_id: @lean, subject_id: "ada", facet: "title", end_state: {}, pinned_by_id: @editor_id,
                                      pinned_from: [ @q1, inherited.event_id ])
    assert_equal [ TitleDropped, @q1 ], [ inherited.class, @plan.inherited_change(@lean, %w[ada title]).first ]
    assert_equal [ TitleDropped ], @plan.changes_in(@lean).map(&:class)
  end

  should "rebuild clears and pins from the stream" do
    set(@q1, "Senior Engineer")
    set(@lean, "Lead Engineer")
    clear(@lean)
    pin(@lean, "Senior Engineer", from: [ @q1, @plan.changes_in(@q1).last.event_id ])
    pin_event = @plan.unpublished_events.to_a.last

    replayed = TeamPlanning::PlanAggregate.new
    @plan.unpublished_events.each { replayed.apply(it) }

    pinned = replayed.changes_in(@lean).sole
    assert_equal [ TitleSet, "Senior Engineer", pin_event.event_id ], [ pinned.class, pinned.data[:title], pinned.event_id ]
  end
end
