# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateUndoTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
  end

  class TeamSet < TeamPlanning::Events::Change
    def self.facet = "team"
    def self.apply_to(map, _data) = map
  end

  setup do
    @plan_id = SecureRandom.uuid_v7
    @ada_id = SecureRandom.uuid_v7
    @grace_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @ada_id, time_zone: "UTC")
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @lean = fork(@q1, "instead")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: "Lean", ends_on:, forked_by_id: @ada_id)
    end
  end

  def last_event = @plan.unpublished_events.to_a.last

  def set(scenario_id, title, kind: TitleSet, by: @ada_id)
    field = kind == TitleSet ? :title : :team
    @plan.set_change(kind, scenario_id:, subject_id: "lin", set_by_id: by, end_state: { field => title })
    last_event.event_id
  end

  def clear(scenario_id, facet: "title")
    @plan.clear_change(scenario_id:, subject_id: "lin", facet:, cleared_by_id: @ada_id)
    last_event.event_id
  end

  def pin(scenario_id, title)
    @plan.pin_change(TitleSet, scenario_id:, subject_id: "lin", facet: "title", end_state: { title: }, pinned_by_id: @ada_id)
    last_event.event_id
  end

  def undo_change(scenario_id, event_id, by: @ada_id) = @plan.undo_change(scenario_id:, event_id:, undone_by_id: by)

  def redo_change(scenario_id, event_id, by: @ada_id) = @plan.redo_change(scenario_id:, event_id:, redone_by_id: by)

  def titles(scenario_id) = @plan.changes_in(scenario_id).filter_map { it.data[:title] }

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "take back a change, bringing back the one before it, and restore it on redo" do
    earlier = set(@lean, "Senior Engineer")
    latest = set(@lean, "Lead Engineer")

    undo_change(@lean, latest)
    assert_equal({ plan_id: @plan_id, scenario_id: @lean, subject_id: "lin", facet: "title", undone_event_id: latest, undone_by_id: @ada_id,
                   in_effect_event_id: earlier }, last_event.data)
    assert_equal [ "Senior Engineer" ], titles(@lean)
    assert @plan.undone?(latest)

    redo_change(@lean, latest)
    assert_equal({ plan_id: @plan_id, scenario_id: @lean, subject_id: "lin", facet: "title", redone_event_id: latest, redone_by_id: @ada_id,
                   in_effect_event_id: latest }, last_event.data)
    assert_equal [ "Senior Engineer", "Lead Engineer" ], titles(@lean)
  end

  should "bring a cleared override back when the clear is undone" do
    set(@q1, "Senior Engineer")
    lead = set(@lean, "Lead Engineer")
    cleared = clear(@lean)
    assert_empty titles(@lean)

    undo_change(@lean, cleared)
    assert_equal [ "Lead Engineer" ], titles(@lean)
    assert_equal lead, last_event.data[:in_effect_event_id]
  end

  should "hand a pinned facet back to the parent when the pin is undone" do
    set(@q1, "Senior Engineer")
    pinned = pin(@lean, "Senior Engineer")
    set(@q1, "Staff Engineer")
    assert_equal [ "Senior Engineer" ], titles(@lean)

    undo_change(@lean, pinned)
    assert_empty titles(@lean)
    assert_nil last_event.data[:in_effect_event_id]
    assert_equal "Staff Engineer", @plan.inherited_change(@lean, %w[lin title]).last.data[:title]
  end

  should "refuse to undo a change a later one replaced, naming the later one" do
    first = set(@lean, "Senior Engineer")
    second = set(@lean, "Lead Engineer")

    assert_equal "A later change to this replaced it (#{second}): undo that first, then undo this", refusal { undo_change(@lean, first) }

    undo_change(@lean, second)
    undo_change(@lean, first)
    assert_empty titles(@lean)
  end

  should "refuse to undo a change under a later clear of it" do
    set_id = set(@lean, "Lead Engineer")
    cleared = clear(@lean)

    assert_match(/replaced it \(#{cleared}\)/, refusal { undo_change(@lean, set_id) })
  end

  should "refuse to redo a change once a newer one to the same facet was made" do
    first = set(@lean, "Senior Engineer")
    undo_change(@lean, first)
    newer = set(@lean, "Lead Engineer")

    assert_equal "A later change to this replaced it (#{newer}): undo that first, then redo this", refusal { redo_change(@lean, first) }
  end

  should "undo changes to different facets on their own" do
    title = set(@lean, "Lead Engineer")
    set(@lean, "Platform", kind: TeamSet)

    undo_change(@lean, title)
    assert_equal [ { team: "Platform" } ], @plan.changes_in(@lean).map { it.data.slice(:team) }
  end

  should "let a child follow its parent's undo" do
    set(@q1, "Senior Engineer")
    latest = set(@q1, "Lead Engineer")

    undo_change(@q1, latest)
    assert_equal "Senior Engineer", @plan.inherited_change(@lean, %w[lin title]).last.data[:title]
  end

  should "refuse what there is nothing to undo or redo" do
    change = set(@lean, "Lead Engineer")

    assert_equal "That change isn't undone, so there is nothing to redo", refusal { redo_change(@lean, change) }
    undo_change(@lean, change)
    assert_equal "That change is already undone", refusal { undo_change(@lean, change) }
    assert_equal "This scenario has no such change", refusal { undo_change(@lean, SecureRandom.uuid_v7) }
    assert_equal "This scenario has no such change", refusal { undo_change(@q1, change) }
    assert_equal "This plan has no such scenario", refusal { undo_change(SecureRandom.uuid_v7, change) }
  end

  should "pick a person's own latest change for Undo, and what their latest undo took back for Redo" do
    mine = set(@lean, "Lead Engineer")
    theirs = set(@lean, "Platform", kind: TeamSet, by: @grace_id)

    assert_equal mine, @plan.last_undoable_by(@lean, @ada_id)
    assert_equal theirs, @plan.last_undoable_by(@lean, @grace_id)
    assert_nil @plan.last_redoable_by(@lean, @ada_id)

    undo_change(@lean, mine)
    assert_nil @plan.last_undoable_by(@lean, @ada_id)
    assert_equal mine, @plan.last_redoable_by(@lean, @ada_id)
    assert_nil @plan.last_redoable_by(@lean, @grace_id)
  end

  should "skip a person's change for Undo once someone else replaced it" do
    set(@lean, "Lead Engineer")
    set(@lean, "Staff Engineer", by: @grace_id)

    assert_nil @plan.last_undoable_by(@lean, @ada_id)
  end

  should "fall back to a person's older change on another facet once their latest was replaced" do
    title = set(@lean, "Lead Engineer")
    set(@lean, "Platform", kind: TeamSet)
    set(@lean, "Data", kind: TeamSet, by: @grace_id)

    assert_equal title, @plan.last_undoable_by(@lean, @ada_id)
  end

  should "leave Redo to whoever undid a change last" do
    mine = set(@lean, "Lead Engineer")
    undo_change(@lean, mine)
    redo_change(@lean, mine, by: @grace_id)
    undo_change(@lean, mine, by: @grace_id)

    assert_nil @plan.last_redoable_by(@lean, @ada_id)
    assert_equal mine, @plan.last_redoable_by(@lean, @grace_id)
  end

  should "end what a person can redo once they make a change" do
    title = set(@lean, "Lead Engineer")
    undo_change(@lean, title)
    set(@lean, "Platform", kind: TeamSet, by: @grace_id)
    assert_equal title, @plan.last_redoable_by(@lean, @ada_id)

    set(@lean, "Platform", kind: TeamSet)
    assert_nil @plan.last_redoable_by(@lean, @ada_id)
  end

  should "refuse undo and redo on a deleted plan" do
    change = set(@lean, "Lead Engineer")
    @plan.delete(deleted_by_id: @ada_id)

    assert_equal "This plan has been deleted", refusal { undo_change(@lean, change) }
    assert_equal "This plan has been deleted", refusal { @plan.last_undoable_by(@lean, @ada_id) }
    assert_equal "This plan has been deleted", refusal { @plan.last_redoable_by(@lean, @ada_id) }
  end

  should "rebuild what stands undone from the stream" do
    set(@lean, "Senior Engineer")
    latest = set(@lean, "Lead Engineer")
    undo_change(@lean, latest)

    replayed = TeamPlanning::PlanAggregate.new
    @plan.unpublished_events.each { replayed.apply(it) }
    assert_equal [ "Senior Engineer" ], replayed.changes_in(@lean).filter_map { it.data[:title] }
    assert replayed.undone?(latest)
  end
end
