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

  should "stop naming someone the baseline covers once they leave the plan's units" do
    @base = @base.with(people: [ Someone.new("ada", [ Place.new(@engineering) ]), Someone.new("bo", [ Place.new(@engineering) ]) ])
    left = change(:moved, 10, person_id: "ada", unit_id: @sales, from_unit_id: @engineering)
    manager = change(:fact_changed, 20, person_id: "bo", fact: "manager", before: { "manager_id" => nil }, after: { "manager_id" => "ada" })

    assert_equal [ { "manager_id" => nil }, [ "after" ] ], cuts(left, manager).last.then { [ it.change.after, it.outside ] }
  end

  should "keep only what a joiner holds inside the plan" do
    joined = change(:joined, 10, after: { "title" => "Staff Engineer", "manager_id" => "cy",
                                          "memberships" => { @engineering => { "allocation" => 1 }, @sales => { "allocation" => 0 } },
                                          "owned_unit_ids" => [ @engineering, @sales ] })
    cut = cuts(joined).sole

    assert_equal [ { "title" => "Staff Engineer", "manager_id" => nil, "memberships" => { @engineering => { "allocation" => 1 } }, "owned_unit_ids" => [ @engineering ] },
                   [ "after" ] ], [ cut.change.after, cut.outside ]
  end

  should "name a joiner's manager who joins the same day, and count someone joining a unit created that day" do
    @base = @base.with(outside: [])
    joiner = ->(id, manager_id, unit_id) { change(:joined, 10, person_id: id, after: { "manager_id" => manager_id, "memberships" => { unit_id => {} } }) }
    created = change(:unit_created, 10, person_id: nil, unit_id: "field", after: { "parent_id" => @engineering })
    kept = cuts(joiner.call("cy", "dee", @engineering), joiner.call("dee", nil, @engineering), joiner.call("eve", nil, "field"), created)

    assert_equal [ [ "cy", "dee" ], [ "dee", nil ], [ "eve", nil ] ], kept.filter_map { [ it.change.person_id, it.change.after["manager_id"] ] if it.change.kind == :joined }
  end

  should "follow a move known before the window from its day, and drop it once the window withdraws it" do
    title = change(:fact_changed, 20, fact: "title", before: { "title" => "Engineer" }, after: { "title" => "Staff Engineer" })
    known = change(:moved, 15, unit_id: @engineering, from_unit_id: @sales)
    counted = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ title ], known: [ known ])
    withdrawn = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ known.with(withdrawn: true), title ], known: [ known ])

    assert_equal [ [ title.event_id ], [] ], [ counted, withdrawn ].map { |kept| kept.map(&:change).select { it.kind == :fact_changed }.map(&:event_id) }
  end

  should "show a unit known to be created inside the plan, so its first rename keeps the name it was given" do
    created = change(:unit_created, 5, person_id: nil, unit_id: "field", after: { "parent_id" => @engineering, "name" => "Field" })
    renamed = change(:unit_renamed, 20, person_id: nil, unit_id: "field", before: { "name" => "Field" }, after: { "name" => "Field Ops" })

    assert_equal [ [ { "name" => "Field" }, [] ] ], TeamPlanning::DriftScope.new(@base, [ @base ]).call([ renamed ], known: [ created ]).map { [ it.change.before, it.outside ] }
  end
end
