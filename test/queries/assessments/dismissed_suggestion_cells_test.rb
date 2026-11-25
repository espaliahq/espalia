# frozen_string_literal: true

require "test_helper"

class Assessments::DismissedSuggestionCellsTest < ActiveSupport::TestCase
  E = PersonDevelopment::Events

  def suggested(id, stable_id, level = 3)
    E::EvidencePlacementSuggested.new(data: { suggestion_id: id, evidence_id: "item", capability_stable_id: stable_id,
                                              level_ordinal: level })
  end

  def dismissed(id) = E::EvidencePlacementSuggestionDismissed.new(data: { suggestion_id: id, evidence_id: "item" })

  def migrated(*mappings)
    E::FrameworkVersionMigrated.new(data: { framework_id: "fw", old_version: 1, new_version: 2,
                                            mappings: mappings.map { |from, to, type| { from_stable_id: from, to_stable_id: to, mapping_type: type } } })
  end

  should "give each dismissed suggestion the cell it was made on, and leave out the rest" do
    cells = Assessments::DismissedSuggestionCells.from([ suggested("s1", "a"), suggested("s2", "b", 2), dismissed("s2") ])

    assert_equal({ "s2" => [ "b", 2 ] }, cells)
  end

  should "carry both dismissals onto the survivor when a migration lands them on one cell" do
    events = [ suggested("s1", "a"), dismissed("s1"), suggested("s2", "b"), dismissed("s2"), migrated([ "a", "b", "evolved" ]) ]

    assert_equal({ "s1" => [ "b", 3 ], "s2" => [ "b", 3 ] }, Assessments::DismissedSuggestionCells.from(events))
  end

  should "leave a dismissal on an archived or split capability where it was" do
    events = [ suggested("s1", "a"), dismissed("s1"), migrated([ "a", nil, "archived" ], [ "a", "c", "split" ]) ]

    assert_equal({ "s1" => [ "a", 3 ] }, Assessments::DismissedSuggestionCells.from(events))
  end

  should "apply a migration's mappings one after another, as the rows move" do
    events = [ suggested("s1", "a"), dismissed("s1"), migrated([ "a", "b", "same" ], [ "b", "c", "evolved" ]) ]

    assert_equal({ "s1" => [ "c", 3 ] }, Assessments::DismissedSuggestionCells.from(events))
  end

  should "keep the cell a suggestion was dismissed on when the same id is proposed again" do
    events = [ suggested("s1", "a"), dismissed("s1"), suggested("s1", "z") ]

    assert_equal({ "s1" => [ "a", 3 ] }, Assessments::DismissedSuggestionCells.from(events))
  end
end
