# frozen_string_literal: true

require "test_helper"
require_relative "../../support/rebuild_lock"

class OrgGraph::DeclareStructureTest < ActiveSupport::TestCase
  include RebuildLock

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @admin = OrgGraph::StructureCommandHandler.new(actor: admin_context)
    @today = Date.new(2026, 11, 1)
    @tribe, @squad, @pod, @group, @stream = Array.new(5) { SecureRandom.uuid_v7 }
    as_tenant do
      @handler.define_taxonomy([ { level_id: @tribe, name: "Tribe" }, { level_id: @squad, name: "Squad" }, { level_id: @pod, name: "Pod" } ],
                               effective_on: @today)
    end
    @payments = create_unit("Payments", @tribe)
    @checkout = create_unit("Checkout", @squad, parent_id: @payments)
    @basket = create_unit("Basket", @pod, parent_id: @checkout)
  end

  should "give a unit its own structure, converting every unit beneath it in the same change" do
    event_store.with_metadata(correlation_id: "request-1") { declare }

    assert_equal [ @payments, @payments ], [ @checkout, @basket ].map { structure.structure_in_force(it) }
    assert_equal [ @group, @stream ], [ @checkout, @basket ].map { structure.unit(it).level_id }
    assert_equal @tribe, structure.unit(@payments).level_id
    assert_empty structure.misplaced_units

    defined = event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).backward.first
    assert_equal [ @payments, { @squad => @group, @pod => @stream } ], defined.data.values_at(:structure_unit_id, :conversion)
    assert_equal [ "request-1" ] * 3,
                 [ defined, *event_store.read.of_type(OrgGraph::Events::UnitKindChanged).to_a ].map { it.metadata[:correlation_id] }
  end

  should "refuse a conversion that leaves a held type out, or seats a unit where the new rules don't allow" do
    error = assert_raises(RuntimeError) { declare(conversion: { @squad => @group }) }
    assert_equal "Say what Pod units become", error.message

    error = assert_raises(RuntimeError) { declare(conversion: { @squad => @stream, @pod => @stream }) }
    assert_equal "These units wouldn't fit Payments's structure: Basket (Stream under Stream), Checkout (Stream at the top)", error.message
    assert_empty structure.declared_structures
  end

  should "refuse a type id another structure holds, a second structure on one unit, and a date before a change beneath" do
    error = assert_raises(ArgumentError) { declare(levels: [ { level_id: @tribe, name: "Group" } ]) }
    assert_equal "Level id is taken", error.message

    create_unit("Till", @pod, parent_id: @checkout, on: @today + 2)
    error = assert_raises(RuntimeError) { declare(on: @today + 1) }
    assert_equal "Till changed on #{(@today + 2).iso8601}, so date this then or later", error.message

    declare(on: @today + 2)
    error = assert_raises(RuntimeError) { declare(levels: [ { level_id: SecureRandom.uuid_v7, name: "Lane" } ]) }
    assert_equal "Payments already has its own structure", error.message
  end

  should "refuse a date before the declaring unit was created" do
    ledger = create_unit("Ledger", @tribe, on: @today + 3)
    error = assert_raises(RuntimeError) { declare(unit: ledger, levels: [ { level_id: @group, name: "Group" } ], conversion: {}, on: @today + 1) }
    assert_equal "Ledger was created on #{(@today + 3).iso8601}, so date this then or later", error.message
  end

  should "refuse a move beneath a unit's own structure as a loop, not as a change of structure" do
    declare
    error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(@payments, @basket, effective_on: @today) } }
    assert_equal "A unit can't move beneath itself or a unit below it", error.message
  end

  should "refuse a structure over a unit an HRIS supplies beneath it" do
    as_tenant do
      @handler.hand_over_level(@tribe, "hibob", field: "work.tribe", matches: { @payments => "t-1" }, effective_on: @today)
      @handler.hand_over_level(@squad, "hibob", field: "work.squad", matches: { @checkout => "s-1" }, effective_on: @today)
    end

    error = assert_raises(RuntimeError) { declare }
    assert_equal "Checkout comes from HiBob, so Payments can't have a structure of its own over it", error.message
    assert_empty structure.declared_structures
  end

  should "take a declaring unit's structure with it when it moves within the structure above" do
    declare(unit: @checkout, conversion: { @pod => @group })
    lending = create_unit("Lending", @tribe)
    as_tenant { @handler.move_unit(@checkout, lending, effective_on: @today + 1) }

    assert_equal [ lending, @checkout, @group ],
                 [ structure.unit(@checkout).parent_id, structure.structure_in_force(@basket), structure.unit(@basket).level_id ]
    assert_empty structure.misplaced_units
    assert_equal [ { @checkout => %w[Group Stream] } ] * 2, [ @today, @today + 1 ].map { structures_as_of(it) }
  end

  should "copy a type from the structure it copies, and refuse one that structure doesn't hold" do
    declare(copied_from: "top", levels: groups_and_streams.map { it.merge(copied_from_level_id: @squad) })
    assert_equal [ "top", @squad ], [ last_definition[:copied_from], last_definition[:levels].first[:copied_from_level_id] ]

    lending = create_unit("Lending", @tribe)
    error = assert_raises(ArgumentError) do
      declare(unit: lending, copied_from: @payments, levels: [ { level_id: SecureRandom.uuid_v7, name: "Lane", copied_from_level_id: @tribe } ],
              conversion: {})
    end
    assert_equal "Lane copies a unit type the structure copied from doesn't hold", error.message
  end

  should "read another tenant's structure or type ids as unknown" do
    other = create(:tenant)
    lending, lane, tribe = Array.new(3) { SecureRandom.uuid_v7 }
    ActsAsTenant.with_tenant(other) do
      @handler.define_taxonomy([ { level_id: tribe, name: "Tribe" } ], effective_on: @today)
      @handler.create_unit(lending, "Lending", level_id: tribe, effective_on: @today)
      @admin.declare_structure(lending, levels: [ { level_id: lane, name: "Lane" } ], conversion: {}, effective_on: @today)
    end

    error = assert_raises(ArgumentError) { declare(copied_from: lending) }
    assert_equal "No unit has that structure to copy", error.message

    error = assert_raises(ArgumentError) { declare(conversion: { @squad => lane, @pod => @stream }) }
    assert_equal "The conversion names a unit type Payments's structure doesn't hold", error.message
    assert_empty structure.declared_structures
  end

  should "withdraw a structure, converting the units beneath it back into the structure above" do
    declare
    as_tenant { @admin.withdraw_structure(@payments, conversion: { @group => @squad, @stream => @pod }, effective_on: @today) }

    assert_empty structure.declared_structures
    assert_equal [ @squad, @pod ], [ @checkout, @basket ].map { structure.unit(it).level_id }
    assert_empty structure.misplaced_units
    assert_equal %w[Group Stream], last_definition[:previous_levels].map { it[:name] }

    error = assert_raises(RuntimeError) { as_tenant { @admin.withdraw_structure(@payments, conversion: {}, effective_on: @today) } }
    assert_equal "Payments has no structure of its own", error.message
  end

  should "refuse a withdrawal into a type the rules above don't allow there" do
    declare
    error = assert_raises(RuntimeError) do
      as_tenant { @admin.withdraw_structure(@payments, conversion: { @group => @tribe, @stream => @pod }, effective_on: @today) }
    end
    assert_equal "These units wouldn't fit the organisation's structure: Checkout (Tribe under Tribe)", error.message
  end

  should "refuse a withdrawal into a type the structure above gains only later, and allow it from that day" do
    declare
    lane = SecureRandom.uuid_v7
    as_tenant { @handler.add_level(lane, "Lane", parent_ids: [ @squad ], effective_on: @today + 5) }
    conversion = { @group => @squad, @stream => lane }

    error = assert_raises(RuntimeError) do
      as_tenant { @admin.withdraw_structure(@payments, conversion:, effective_on: @today + 2) }
    end
    assert_equal "Lane begins on #{(@today + 5).iso8601}, so date this then or later", error.message

    as_tenant { @admin.withdraw_structure(@payments, conversion:, effective_on: @today + 5) }
    assert_equal lane, structure.unit(@basket).level_id
  end

  should "refuse a withdrawal dated before the declaring unit last changed type, and allow it from that day" do
    declare
    realm = SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(realm, "Realm", parent_ids: [], top: true, effective_on: @today)
      @handler.set_kind_parents(@squad, parent_ids: [ realm ], top: false, effective_on: @today)
      @handler.change_unit_kind(@payments, realm, effective_on: @today + 4)
    end
    conversion = { @group => @squad, @stream => @pod }

    error = assert_raises(RuntimeError) do
      as_tenant { @admin.withdraw_structure(@payments, conversion:, effective_on: @today + 2) }
    end
    assert_equal "Payments changed on #{(@today + 4).iso8601}, so date this then or later", error.message

    as_tenant { @admin.withdraw_structure(@payments, conversion:, effective_on: @today + 4) }
    assert_equal @squad, structure.unit(@checkout).level_id
  end

  should "refuse a change inside a declared structure dated before it last changed, and allow one on that day" do
    declare
    lane = SecureRandom.uuid_v7
    search = create_unit("Search", @group, parent_id: @payments)
    as_tenant { @admin.add_level(lane, "Lane", parent_ids: [ @group ], structure_unit_id: @payments, effective_on: @today + 3) }
    refusal = "Payments's structure last changed on #{(@today + 3).iso8601}, so date the change then or later"

    [ -> { @handler.change_unit_kind(@basket, lane, effective_on: @today + 2) },
      -> { @handler.move_unit(@basket, search, effective_on: @today + 2) } ].each do |change|
      assert_equal refusal, assert_raises(RuntimeError) { as_tenant(&change) }.message
    end

    as_tenant do
      @handler.change_unit_kind(@basket, lane, effective_on: @today + 3)
      @handler.move_unit(@basket, search, effective_on: @today + 3)
    end
    assert_equal [ lane, search ], structure.unit(@basket).then { [ it.level_id, it.parent_id ] }
  end

  should "refuse a withdrawal into a declared structure dated before it last changed, and allow one on that day" do
    declare
    leaf, lane = Array.new(2) { SecureRandom.uuid_v7 }
    declare(unit: @checkout, levels: [ { level_id: leaf, name: "Leaf" } ], conversion: { @stream => leaf }, on: @today + 1)
    as_tenant { @admin.add_level(lane, "Lane", parent_ids: [ @group ], structure_unit_id: @payments, effective_on: @today + 6) }

    error = assert_raises(RuntimeError) do
      as_tenant { @admin.withdraw_structure(@checkout, conversion: { leaf => lane }, effective_on: @today + 4) }
    end
    assert_equal "Payments's structure last changed on #{(@today + 6).iso8601}, so date the change then or later", error.message

    as_tenant { @admin.withdraw_structure(@checkout, conversion: { leaf => lane }, effective_on: @today + 6) }
    assert_equal lane, structure.unit(@basket).level_id
  end

  should "convert the units beneath on the day a structure is declared or withdrawn, after a change on that day" do
    declare(on: @today + 2)
    lane = SecureRandom.uuid_v7
    as_tenant do
      @admin.add_level(lane, "Lane", parent_ids: [ @group ], structure_unit_id: @payments, effective_on: @today + 3)
      @admin.withdraw_structure(@payments, conversion: { @group => @squad, @stream => @pod }, effective_on: @today + 3)
    end

    converted = event_store.read.of_type(OrgGraph::Events::UnitKindChanged).map { it.data.values_at(:unit_id, :level_id, :effective_on) }
    assert_equal [ [ @checkout, @group, (@today + 2).iso8601 ], [ @basket, @stream, (@today + 2).iso8601 ],
                   [ @checkout, @squad, (@today + 3).iso8601 ], [ @basket, @pod, (@today + 3).iso8601 ] ], converted
  end

  context "dating a change inside a declared structure" do
    setup do
      @lane = SecureRandom.uuid_v7
      declare(levels: [ *groups_and_streams, { level_id: @lane, name: "Lane", parent_level_ids: [], top: true } ])
      @search = create_unit("Search", @group, parent_id: @payments)
      @wharf = create_unit("Wharf", @lane, parent_id: @payments)
      as_tenant { @handler.move_unit(@basket, @search, effective_on: @today + 4) }
    end

    should "refuse a type a sub-unit couldn't sit beneath before it left" do
      error = assert_raises(RuntimeError) { as_tenant { @handler.change_unit_kind(@checkout, @lane, effective_on: @today + 2) } }
      assert_equal "On #{(@today + 2).iso8601}, Lane wouldn't have fit: Basket (Stream under Lane). Date the change later", error.message

      as_tenant { @handler.change_unit_kind(@checkout, @lane, effective_on: @today + 4) }
      assert_equal @lane, structure.unit(@checkout).level_id
    end

    should "refuse a back-dated move beneath a type the rules forbid" do
      error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(@basket, @wharf, effective_on: @today + 2) } }
      assert_equal "On #{(@today + 2).iso8601}, Stream couldn't sit under Lane, so the change can't be dated before its rules allowed it",
                   error.message
    end
  end

  should "move a tenant-wide type into one unit's structure, then retire it tenant-wide (the worked example)" do
    declared_on = @today + 3
    group = SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(group, "Group", effective_on: @today)
      @handler.set_kind_parents(group, parent_ids: [ @tribe ], top: false, effective_on: @today)
      @handler.set_kind_parents(@squad, parent_ids: [ @tribe, group ], top: false, effective_on: @today)
    end
    core = create_unit("Core", group, parent_id: @payments)
    as_tenant { @handler.move_unit(@checkout, core, effective_on: @today) }
    cards = create_unit("Cards", @squad, parent_id: @payments)
    loans = create_unit("Loans", @squad, parent_id: create_unit("Lending", @tribe))

    copies = { group => SecureRandom.uuid_v7, @squad => SecureRandom.uuid_v7, @pod => SecureRandom.uuid_v7 }
    declare(on: declared_on, copied_from: "top", conversion: copies, levels: [
      { level_id: copies[group], name: "Group", parent_level_ids: [], top: true, copied_from_level_id: group },
      { level_id: copies[@squad], name: "Squad", parent_level_ids: [ copies[group] ], top: true, copied_from_level_id: @squad },
      { level_id: copies[@pod], name: "Pod", parent_level_ids: [ copies[@squad] ], top: false, copied_from_level_id: @pod }
    ])
    error = assert_raises(RuntimeError) { as_tenant { @handler.remove_level(group, effective_on: declared_on - 1) } }
    assert_equal "Core was a Group until #{(declared_on - 1).iso8601}, so date its removal after then", error.message
    as_tenant { @handler.remove_level(group, effective_on: declared_on) }

    assert_equal copies.values_at(group, @squad, @squad, @pod), [ core, @checkout, cards, @basket ].map { structure.unit(it).level_id }
    assert_equal [ @tribe, @squad ], [ @payments, loans ].map { structure.unit(it).level_id }
    assert_equal %w[Tribe Squad Pod], structure.taxonomy.kinds.map(&:name)
    assert_empty structure.misplaced_units

    before, after = [ declared_on - 1, declared_on ].map { snapshot_on(it) }
    assert_equal [ %w[Tribe Squad Pod Group], {} ], [ before.kinds.map(&:name), before.structures ]
    assert_equal [ %w[Tribe Squad Pod], { @payments => %w[Group Squad Pod] } ],
                 [ after.kinds.map(&:name), after.structures.transform_values { it.map(&:name) } ]
    assert_equal [ group, copies[group] ], [ before, after ].map { |snapshot| snapshot.units.find { it.id == core }.level_id }
  end

  context "editing a declared structure's types" do
    setup { declare }

    should "add a type, set its rules and remove it again, each as a change to that structure" do
      lane = SecureRandom.uuid_v7
      as_tenant do
        @admin.add_level(lane, "Lane", structure_unit_id: @payments, effective_on: @today)
        @admin.set_kind_parents(lane, parent_ids: [ @stream ], top: false, structure_unit_id: @payments, effective_on: @today)
      end
      assert_equal [ [ @stream ], false ], structure.declared_structures[@payments].kind(lane).then { [ it.parent_ids, it.top ] }
      assert_equal %w[Tribe Squad Pod], structure.taxonomy.kinds.map(&:name)

      as_tenant { @admin.remove_level(lane, structure_unit_id: @payments, effective_on: @today) }
      assert_equal %w[Group Stream], structure.declared_structures[@payments].kinds.map(&:name)
      assert_equal %w[Group Stream Lane], last_definition[:previous_levels].map { it[:name] }
    end

    should "refuse rules a unit it governs wouldn't fit, a type a unit has held, and the structure's last type" do
      error = assert_raises(RuntimeError) do
        as_tenant { @admin.set_kind_parents(@stream, parent_ids: [], top: true, structure_unit_id: @payments, effective_on: @today) }
      end
      assert_equal "These units wouldn't fit Payments's structure: Basket (Stream under Group)", error.message

      error = assert_raises(RuntimeError) { as_tenant { @admin.remove_level(@stream, structure_unit_id: @payments, effective_on: @today) } }
      assert_match "Basket", error.message

      lone = create_unit("Lending", @tribe)
      declare(unit: lone, levels: [ { level_id: SecureRandom.uuid_v7, name: "Lane" } ], conversion: {})
      lane = structure.declared_structures[lone].kinds.sole.id
      error = assert_raises(ArgumentError) { as_tenant { @admin.remove_level(lane, structure_unit_id: lone, effective_on: @today) } }
      assert_equal "A structure needs at least one unit type; withdraw it instead", error.message
    end

    should "keep the tenant-wide structure from taking a type id a declared structure holds" do
      tenant_wide = [ { level_id: @tribe, name: "Tribe" }, { level_id: @squad, name: "Squad" }, { level_id: @pod, name: "Pod" } ]
      error = assert_raises(ArgumentError) do
        as_tenant { @handler.define_taxonomy([ *tenant_wide, { level_id: @group, name: "Group" } ], effective_on: @today) }
      end
      assert_equal "Level id is taken", error.message
      assert_equal %w[Tribe Squad Pod], structure.taxonomy.kinds.map(&:name)
    end

    should "refuse a top structure type id named for a declared structure" do
      error = assert_raises(ArgumentError) do
        as_tenant { @admin.set_kind_parents(@squad, parent_ids: [], top: true, structure_unit_id: @payments, effective_on: @today) }
      end
      assert_equal "That unit type doesn't exist", error.message
    end

    should "refuse each type command a type id from a structure other than the one it names" do
      lending = create_unit("Lending", @tribe)
      lane = SecureRandom.uuid_v7
      declare(unit: lending, levels: [ { level_id: lane, name: "Lane" } ], conversion: {})
      before = [ structure.taxonomy, *structure.declared_structures.values_at(@payments, lending) ].map { it.kinds.map(&:to_h) }

      { "the top structure's type named for Payments" => [ @squad, @payments ],
        "Payments's type named for the top structure" => [ @stream, nil ],
        "Payments's type named for Lending" => [ @stream, lending ],
        "Lending's type named for Payments" => [ lane, @payments ] }.each do |label, (level_id, named)|
        commands = {
          add_level: -> { @admin.add_level(level_id, "Copy", parent_ids: [], top: true, structure_unit_id: named, effective_on: @today) },
          set_kind_parents: -> { @admin.set_kind_parents(level_id, parent_ids: [], top: true, structure_unit_id: named, effective_on: @today) },
          remove_level: -> { @admin.remove_level(level_id, structure_unit_id: named, effective_on: @today) }
        }
        commands.each do |command, run|
          error = assert_raises(ArgumentError, "#{command}: #{label}") { as_tenant { run.call } }
          expected = command == :add_level ? "Level id is taken" : "That unit type doesn't exist"
          assert_equal expected, error.message, "#{command}: #{label}"
        end
      end

      assert_equal before, [ structure.taxonomy, *structure.declared_structures.values_at(@payments, lending) ].map { it.kinds.map(&:to_h) }
    end
  end

  should "refuse the system any change to a unit's own structure, and let it change the top structure" do
    declare
    lane = SecureRandom.uuid_v7
    before = event_store.read.stream(as_tenant { EventStreamNaming.org_structure_stream }).count

    {
      declare_structure: -> { @handler.declare_structure(@basket, levels: [ { level_id: lane, name: "Lane" } ], conversion: {}, effective_on: @today) },
      withdraw_structure: -> { @handler.withdraw_structure(@payments, conversion: { @group => @squad, @stream => @pod }, effective_on: @today) },
      add_level: -> { @handler.add_level(lane, "Lane", parent_ids: [ @stream ], structure_unit_id: @payments, effective_on: @today) },
      set_kind_parents: -> { @handler.set_kind_parents(@stream, parent_ids: [], top: true, structure_unit_id: @payments, effective_on: @today) },
      remove_level: -> { @handler.remove_level(@stream, structure_unit_id: @payments, effective_on: @today) }
    }.each do |command, call|
      error = assert_raises(OrgGraph::Authorization::Refused, command.to_s) { as_tenant(&call) }
      assert_equal "The system cannot change a structure", error.message
    end
    assert_equal before, event_store.read.stream(as_tenant { EventStreamNaming.org_structure_stream }).count

    as_tenant { @handler.add_level(lane, "Lane", parent_ids: [ @tribe ], effective_on: @today) }
    assert_equal %w[Tribe Squad Pod Lane], structure.taxonomy.kinds.map(&:name)
  end

  context "retiring a unit with a structure of its own" do
    setup do
      @lane = SecureRandom.uuid_v7
      @retire_on = @today + 5
    end

    should "withdraw the structure in the same change when an admin retires the unit" do
      declare(unit: @basket, levels: [ { level_id: @lane, name: "Lane" } ], conversion: {})
      event_store.with_metadata(correlation_id: "request-1") do
        as_tenant { @admin.retire_unit(@basket, effective_on: @retire_on) }
      end

      assert structure.unit(@basket).retired
      assert_empty structure.declared_structures
      assert_equal [ [], [ "Lane" ], "request-1" ],
                   last_definition.then { [ it[:levels], it[:previous_levels].map { |level| level[:name] }, last_event.metadata[:correlation_id] ] }
      assert_equal "request-1", event_store.read.of_type(OrgGraph::Events::UnitRetired).backward.first.metadata[:correlation_id]
      assert_equal [ { @basket => %w[Lane] }, {} ], [ @retire_on - 1, @retire_on ].map { structures_as_of(it) }
    end

    should "refuse a retirement, succession or applied succession that withdraws a structure while the kinds are rebuilt, and retire any other unit" do
      declare(unit: @basket, levels: [ { level_id: @lane, name: "Lane" } ], conversion: {})
      till, ledger = %w[Till Ledger].map { create_unit(it, @pod, parent_id: @checkout) }
      while_rebuilding(@tenant, OrgGraph::Projections::History) { as_tenant { @handler.retire_unit(ledger, effective_on: @retire_on) } }
      assert structure.unit(ledger).retired

      before = event_store.read.stream(as_tenant { EventStreamNaming.org_structure_stream }).count

      [ OrgGraph::Projections::History, OrgGraph::Projections::Structure ].each do |projection|
        while_rebuilding(@tenant, projection) do
          as_tenant do
            assert_raises(ProjectionVersion::Rebuilding) { @handler.retire_unit(@basket, effective_on: @retire_on) }
            assert_raises(ProjectionVersion::Rebuilding) do
              @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @basket ], successor_ids: [ till ],
                                                               effective_on: @retire_on, retire_predecessors: true)
            end
            assert_raises(ProjectionVersion::Rebuilding) do
              @handler.apply_succession(SecureRandom.uuid_v7, predecessor_ids: [ @basket ], successor_ids: [ till ],
                                                              effective_on: @retire_on)
            end
          end
        end
      end
      assert_equal before, event_store.read.stream(as_tenant { EventStreamNaming.org_structure_stream }).count
    end

    should "refuse an admin's retirement dated before the structure last changed" do
      declare(unit: @basket, levels: [ { level_id: @lane, name: "Lane" } ], conversion: {}, on: @today + 3)

      error = assert_raises(RuntimeError) { as_tenant { @admin.retire_unit(@basket, effective_on: @today + 1) } }
      assert_equal "Basket's structure last changed on #{(@today + 3).iso8601}, so date its retirement then or later", error.message
      assert_equal [ "Lane" ], structures_as_of(@today + 3)[@basket]
    end

    should "withdraw it on its last change when the HRIS dates the retirement earlier" do
      ledger = create_unit("Ledger", @tribe)
      as_tenant { @handler.hand_over_level(@tribe, "hibob", field: "work.tribe", matches: { @payments => "t-1", ledger => "t-2" }, effective_on: @today) }
      declare(unit: ledger, levels: [ { level_id: @lane, name: "Lane" } ], conversion: {}, on: @today + 3)
      as_tenant { @handler.retire_unit(ledger, provider: "hibob", effective_on: @today + 1) }

      assert structure.unit(ledger).retired
      assert_equal [ [], (@today + 3).iso8601 ], [ last_definition[:levels], last_definition[:effective_on].to_s ]
    end

    should "withdraw it when the HRIS retires a unit it provides, never refusing the sync" do
      as_tenant { @handler.hand_over_level(@tribe, "hibob", field: "work.tribe", matches: { @payments => "t-1" }, effective_on: @today) }
      declare
      as_tenant do
        [ @basket, @checkout ].each { @handler.retire_unit(it, effective_on: @retire_on) }
        @handler.retire_unit(@payments, provider: "hibob", effective_on: @retire_on)
      end

      assert structure.unit(@payments).retired
      assert_empty structure.declared_structures
      assert_equal [ { @payments => %w[Group Stream] }, {} ], [ @retire_on - 1, @retire_on ].map { structures_as_of(it) }
    end
  end

  should "share one cause with its conversion outside a request, so change back can't undo one type change alone" do
    declare
    as_tenant { @admin.withdraw_structure(@payments, conversion: { @group => @squad, @stream => @pod }, effective_on: @today) }

    as_tenant do
      change_back = OrgGraph::ChangeBackHandler.new(actor: admin_context)
      causes = OrgUnitActivity.where(subject: "structure").order(:created_at).pluck(:cause_id).uniq
      assert_equal 2, causes.size
      reasons = [ "A later change has replaced this one; change that back first",
                  "This came with a change to a unit's own structure, so change the whole change back" ]
      causes.zip(reasons).each do |cause_id, reason|
        kinds = OrgUnitActivity.where(cause_id:, event_type: "UnitKindChanged").to_a
        assert_equal [ @basket, @checkout ].sort, kinds.map(&:unit_id).sort
        assert_equal @payments, OrgUnitActivity.find_by!(cause_id:, subject: "structure").unit_id
        error = assert_raises(RuntimeError) { change_back.change_back(kinds.first) }
        assert_equal reason, error.message
      end
    end
  end

  private

  def admin_context
    as_tenant do
      tenant_user = create(:tenant_user, tenant: @tenant, role: :admin)
      AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil)
    end
  end

  def last_event = event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).backward.first

  def structures_as_of(day) = snapshot_on(day).structures.transform_values { it.map(&:name) }

  def snapshot_on(day)
    as_tenant do
      user = create(:user)
      context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
      OrgGraph::AsOf.new(context:, date: day).call
    end
  end

  def groups_and_streams
    [ { level_id: @group, name: "Group", parent_level_ids: [], top: true },
      { level_id: @stream, name: "Stream", parent_level_ids: [ @group ], top: false } ]
  end

  def declare(unit: @payments, levels: groups_and_streams, conversion: { @squad => @group, @pod => @stream }, on: @today, **options)
    as_tenant { @admin.declare_structure(unit, levels:, conversion:, effective_on: on, **options) }
  end

  def last_definition = event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).backward.first.data

  def event_store = Rails.configuration.event_store

  def structure = as_tenant { OrgGraph::Repository.new.load_structure }

  def create_unit(name, level_id, parent_id: nil, on: @today)
    unit_id = SecureRandom.uuid_v7
    as_tenant { @handler.create_unit(unit_id, name, level_id:, parent_id:, effective_on: on) }
    unit_id
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
