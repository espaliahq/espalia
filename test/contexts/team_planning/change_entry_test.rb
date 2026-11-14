# frozen_string_literal: true

require "test_helper"

class TeamPlanning::ChangeEntryTest < ActiveSupport::TestCase
  class NoteSet < TeamPlanning::Events::Change
    def self.facet = "note"
    def self.apply_to(map, _data) = map
  end

  def change(**end_state)
    NoteSet.new(data: { plan_id: "p", scenario_id: "s", subject_id: "lin", set_by_id: "ada", **end_state })
  end

  should "keep a shreddable value out of the entry, naming its field instead" do
    entry = TeamPlanning::ChangeEntry.from(change(title: "Lead", note: Shreddable::Value.wrap("Ask about pay")))

    assert_equal({ title: "Lead" }, entry.end_state)
    assert_equal [ "note" ], entry.sealed_fields
    assert_nothing_raised { entry.end_state.to_json }
  end

  should "read a set, naming its facet, kind and who set it" do
    entry = TeamPlanning::ChangeEntry.from(change(title: "Lead"))

    assert_equal [ "set", "lin", "note", NoteSet.name, "ada", [] ],
                 [ entry.action, entry.subject_id, entry.facet, entry.kind, entry.actor_id, entry.sealed_fields ]
    assert entry.sets?
    assert_not entry.reverses?
  end

  should "read an undo as reversing the entry it names" do
    event = TeamPlanning::Events::ChangeUndone.new(data: { plan_id: "p", scenario_id: "s", subject_id: "lin", facet: "note",
                                                           undone_event_id: "e1", undone_by_id: "ada" })
    entry = TeamPlanning::ChangeEntry.from(event)

    assert_equal [ "undo", "e1", "ada" ], [ entry.action, entry.reverses_event_id, entry.actor_id ]
    assert entry.reverses?
  end

  should "read nothing from an event that changes no facet" do
    assert_nil TeamPlanning::ChangeEntry.from(TeamPlanning::Events::PlanDeleted.new(data: { plan_id: "p" }))
  end
end
