# frozen_string_literal: true

require "test_helper"

class TeamPlanning::DriftScopeTest < ActiveSupport::TestCase
  Place = Data.define(:unit_id)
  Someone = Data.define(:id, :memberships)
  Unit = Data.define(:id, :parent_id)
  Map = Data.define(:people, :outside, :units, :scope_ids) do
    def departed = []
    def retired_units = []
    def person_ids = people.to_set(&:id)
    def outside_ids = outside.to_set(&:id)
    def known_unit_ids = units.to_set(&:id)
  end

  setup do
    @engineering, @sales = "engineering", "sales"
    @base = Map.new(people: [], outside: [ Someone.new("dee", [ Place.new(@sales) ]), Someone.new("cy", [ Place.new(@sales) ]) ],
                    units: [ Unit.new(@engineering, nil) ], scope_ids: [ @engineering ])
  end

  def change(kind, on, **fields)
    OrgGraph::ChangesBetween::Change.new(kind:, effective_on: Date.new(2026, 1, on), learned_at: nil, person_id: "dee", unit_id: nil,
                                         from_unit_id: nil, succession_id: nil, fact: nil, before: nil, after: nil, provider: "espalia",
                                         event_id: SecureRandom.uuid, withdrawn: false, **fields)
  end

  def cuts(*changes, parents: {}) = TeamPlanning::DriftScope.new(@base, [ @base ], parents:).call(changes)

  def move_in = change(:moved, 15, unit_id: @engineering, from_unit_id: @sales)

  should "cut a manager the plan can't name even when the earlier one was set outside" do
    manager = cuts(change(:fact_changed, 10, fact: "manager", after: { "manager_id" => "cy" }), move_in,
                   change(:fact_changed, 20, fact: "manager", before: { "manager_id" => "cy" }, after: { "manager_id" => "cy" })).last

    assert_equal [ nil, { "manager_id" => nil }, %w[before after] ], [ manager.change.before, manager.change.after, manager.outside ]
  end

  should "keep cutting an earlier value set outside after a withdrawn change to it" do
    title = ->(on, **fields) { change(:fact_changed, on, fact: "title", before: { "title" => "Sales Engineer" }, after: { "title" => "Staff Engineer" }, **fields) }
    changed = cuts(change(:fact_changed, 10, fact: "title", after: { "title" => "Sales Engineer" }), move_in,
                   title.call(16, withdrawn: true), title.call(20)).last(2)

    assert_equal [ [ nil, [ "before" ] ] ] * 2, changed.map { [ it.change.before, it.outside ] }
  end

  should "count someone in a unit beneath one the window brings in" do
    @base = @base.with(outside: [ Someone.new("eve", [ Place.new("field") ]) ])
    moved = change(:unit_moved, 10, person_id: nil, unit_id: @sales, before: { "parent_id" => nil }, after: { "parent_id" => @engineering })
    title = change(:fact_changed, 20, person_id: "eve", fact: "title", after: { "title" => "Staff Engineer" })

    assert_equal [ "eve" ], cuts(moved, title, parents: { "field" => @sales, @sales => nil }).filter_map { it.change.person_id }
  end
end
