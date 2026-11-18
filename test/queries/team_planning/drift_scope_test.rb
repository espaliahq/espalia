# frozen_string_literal: true

require "test_helper"

class TeamPlanning::DriftScopeTest < ActiveSupport::TestCase
  Place = Data.define(:unit_id)
  Someone = Data.define(:id, :memberships)
  Unit = Data.define(:id, :parent_id)
  Map = Data.define(:people, :outside, :units, :scope_ids) do
    def base_on = Date.new(2026, 1, 1)
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

  def retyped(unit_id, on, before: "team", after: "squad")
    change(:unit_kind_changed, on, person_id: nil, unit_id:, before: { "level_id" => before }, after: { "level_id" => after })
  end

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

  should "report a joiner's own membership change on the day they join" do
    joined = change(:joined, 10, after: { "memberships" => { @engineering => { "allocation" => 1 } } })
    changed = change(:membership_changed, 10, unit_id: @engineering, before: { "allocation" => 1 }, after: { "allocation" => 0.5 })

    assert_equal %i[joined membership_changed], cuts(joined, changed).map { it.change.kind }
  end

  should "keep a known joiner placed when the window withdraws another fact from the same event" do
    known = change(:joined, 5, person_id: "eve", after: { "memberships" => { @engineering => {} } })
    manager = change(:fact_changed, 5, person_id: "eve", fact: "manager", event_id: known.event_id, withdrawn: true)
    title = change(:fact_changed, 20, person_id: "eve", fact: "title", after: { "title" => "Staff Engineer" })

    kept = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ manager, title ], known: [ known ])

    assert_includes kept.map { it.change.event_id }, title.event_id
  end

  should "show a unit known to be created inside the plan, so its first rename keeps the name it was given" do
    created = change(:unit_created, 5, person_id: nil, unit_id: "field", after: { "parent_id" => @engineering, "name" => "Field" })
    renamed = change(:unit_renamed, 20, person_id: nil, unit_id: "field", before: { "name" => "Field" }, after: { "name" => "Field Ops" })

    assert_equal [ [ { "name" => "Field" }, [] ] ], TeamPlanning::DriftScope.new(@base, [ @base ]).call([ renamed ], known: [ created ]).map { [ it.change.before, it.outside ] }
  end

  should "keep unseen a fact known to change while someone was outside, once they come back" do
    @base = @base.with(people: [ Someone.new("ada", [ Place.new(@engineering) ]) ])
    out = change(:moved, 10, person_id: "ada", unit_id: @sales, from_unit_id: @engineering)
    back = change(:moved, 20, person_id: "ada", unit_id: @engineering, from_unit_id: @sales)
    known = change(:fact_changed, 15, person_id: "ada", fact: "title", after: { "title" => "Sales Engineer" })
    title = change(:fact_changed, 25, person_id: "ada", fact: "title", before: { "title" => "Sales Engineer" }, after: { "title" => "Engineer" })

    cut = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ out, back, title ], known: [ known ]).last

    assert_equal [ title.event_id, nil, [ "before" ] ], [ cut.change.event_id, cut.change.before, cut.outside ]
  end

  should "keep unseen a name known to change while a unit was outside, once it comes back" do
    @base = @base.with(units: [ Unit.new(@engineering, nil), Unit.new("field", @engineering) ])
    out = change(:unit_moved, 10, person_id: nil, unit_id: "field", before: { "parent_id" => @engineering }, after: { "parent_id" => @sales })
    back = change(:unit_moved, 20, person_id: nil, unit_id: "field", before: { "parent_id" => @sales }, after: { "parent_id" => @engineering })
    known = change(:unit_renamed, 15, person_id: nil, unit_id: "field", before: { "name" => "Field" }, after: { "name" => "Sales Field" })
    renamed = change(:unit_renamed, 25, person_id: nil, unit_id: "field", before: { "name" => "Sales Field" }, after: { "name" => "Field Ops" })

    cut = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ out, back, renamed ], known: [ known ]).last

    assert_equal [ renamed.event_id, nil, [ "before" ] ], [ cut.change.event_id, cut.change.before, cut.outside ]
  end

  should "keep a fact known to change while someone was covered" do
    @base = @base.with(people: [ Someone.new("ada", [ Place.new(@engineering) ]) ])
    known = change(:fact_changed, 15, person_id: "ada", fact: "title", after: { "title" => "Staff Engineer" })
    title = change(:fact_changed, 25, person_id: "ada", fact: "title", before: { "title" => "Staff Engineer" }, after: { "title" => "Principal" })

    cut = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ title ], known: [ known ]).sole

    assert_equal [ { "title" => "Staff Engineer" }, [] ], [ cut.change.before, cut.outside ]
  end

  should "note a known fact after the day's moves, so one set as someone leaves or arrives goes with the move" do
    @base = @base.with(people: [ Someone.new("ada", [ Place.new(@engineering) ]) ])
    leaves = change(:moved, 10, person_id: "ada", unit_id: @sales, from_unit_id: @engineering)
    back = change(:moved, 20, person_id: "ada", unit_id: @engineering, from_unit_id: @sales)
    arrives = change(:moved, 10, unit_id: @engineering, from_unit_id: @sales)
    known = [ change(:fact_changed, 10, person_id: "ada", fact: "title", after: { "title" => "Sales Engineer" }),
              change(:fact_changed, 10, fact: "title", after: { "title" => "Engineer" }) ]
    titles = [ change(:fact_changed, 25, person_id: "ada", fact: "title", before: { "title" => "Sales Engineer" }, after: { "title" => "Engineer" }),
               change(:fact_changed, 25, fact: "title", before: { "title" => "Engineer" }, after: { "title" => "Staff Engineer" }) ]

    cuts = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ leaves, arrives, back, *titles ], known:)

    assert_equal [ [ "ada", [ "before" ] ], [ "dee", [] ] ], cuts.select { it.change.kind == :fact_changed }.map { [ it.change.person_id, it.outside ] }
  end

  should "drop the earlier value of a change that took effect before the base, though the plan covers its subject now" do
    @base = @base.with(people: [ Someone.new("ada", [ Place.new(@engineering) ]) ])
    title = change(:fact_changed, 10, person_id: "ada", fact: "title", before: { "title" => "Engineer" }, after: { "title" => "Sales Engineer" })

    cut = cuts(title.with(effective_on: Date.new(2025, 12, 10))).sole

    assert_equal [ nil, { "title" => "Sales Engineer" }, [ "before" ] ], [ cut.change.before, cut.change.after, cut.outside ]
  end

  context "a change of unit type" do
    setup do
      @base = @base.with(units: [ Unit.new(@engineering, nil), Unit.new("field", @engineering) ])
    end

    should "show one for a unit the plan covers, before and after" do
      cut = cuts(retyped("field", 20)).sole

      assert_equal [ { "level_id" => "team" }, { "level_id" => "squad" }, [] ], [ cut.change.before, cut.change.after, cut.outside ]
    end

    should "drop one for a unit outside the plan, and for the unit above a scope root, payload and all" do
      @base = @base.with(scope_ids: [ "field" ], units: [ Unit.new("field", @engineering) ])

      assert_empty cuts(retyped(@sales, 20), retyped(@engineering, 21), parents: { "field" => @engineering })
    end

    should "keep unseen a type known to change while the unit was outside, once it comes back" do
      out = change(:unit_moved, 10, person_id: nil, unit_id: "field", before: { "parent_id" => @engineering }, after: { "parent_id" => @sales })
      back = change(:unit_moved, 20, person_id: nil, unit_id: "field", before: { "parent_id" => @sales }, after: { "parent_id" => @engineering })
      known = retyped("field", 15, before: "team", after: "pod")
      again = retyped("field", 25, before: "pod", after: "squad")

      cut = TeamPlanning::DriftScope.new(@base, [ @base ]).call([ out, back, again ], known: [ known ]).last

      assert_equal [ again.event_id, nil, [ "before" ] ], [ cut.change.event_id, cut.change.before, cut.outside ]
    end
  end
end
