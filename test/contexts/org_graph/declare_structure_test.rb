# frozen_string_literal: true

require "test_helper"

class OrgGraph::DeclareStructureTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
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
      @handler.declare_structure(lending, levels: [ { level_id: lane, name: "Lane" } ], conversion: {}, effective_on: @today)
    end

    error = assert_raises(ArgumentError) { declare(copied_from: lending) }
    assert_equal "No unit has that structure to copy", error.message

    error = assert_raises(ArgumentError) { declare(conversion: { @squad => lane, @pod => @stream }) }
    assert_equal "The conversion names a unit type Payments's structure doesn't hold", error.message
    assert_empty structure.declared_structures
  end

  should "withdraw a structure, converting the units beneath it back into the structure above" do
    declare
    as_tenant { @handler.withdraw_structure(@payments, conversion: { @group => @squad, @stream => @pod }, effective_on: @today) }

    assert_empty structure.declared_structures
    assert_equal [ @squad, @pod ], [ @checkout, @basket ].map { structure.unit(it).level_id }
    assert_empty structure.misplaced_units
    assert_equal %w[Group Stream], last_definition[:previous_levels].map { it[:name] }

    error = assert_raises(RuntimeError) { as_tenant { @handler.withdraw_structure(@payments, conversion: {}, effective_on: @today) } }
    assert_equal "Payments has no structure of its own", error.message
  end

  should "refuse a withdrawal into a type the rules above don't allow there" do
    declare
    error = assert_raises(RuntimeError) do
      as_tenant { @handler.withdraw_structure(@payments, conversion: { @group => @tribe, @stream => @pod }, effective_on: @today) }
    end
    assert_equal "These units wouldn't fit the top structure: Checkout (Tribe under Tribe)", error.message
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
        @handler.add_level(lane, "Lane", structure_unit_id: @payments, effective_on: @today)
        @handler.set_kind_parents(lane, parent_ids: [ @stream ], top: false, structure_unit_id: @payments, effective_on: @today)
      end
      assert_equal [ [ @stream ], false ], structure.declared_structures[@payments].kind(lane).then { [ it.parent_ids, it.top ] }
      assert_equal %w[Tribe Squad Pod], structure.taxonomy.kinds.map(&:name)

      as_tenant { @handler.remove_level(lane, structure_unit_id: @payments, effective_on: @today) }
      assert_equal %w[Group Stream], structure.declared_structures[@payments].kinds.map(&:name)
      assert_equal %w[Group Stream Lane], last_definition[:previous_levels].map { it[:name] }
    end

    should "refuse rules a unit it governs wouldn't fit, a type a unit has held, and the structure's last type" do
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@stream, parent_ids: [], top: true, structure_unit_id: @payments, effective_on: @today) }
      end
      assert_equal "These units wouldn't fit Payments's structure: Basket (Stream under Group)", error.message

      error = assert_raises(RuntimeError) { as_tenant { @handler.remove_level(@stream, structure_unit_id: @payments, effective_on: @today) } }
      assert_match "Basket", error.message

      lone = create_unit("Lending", @tribe)
      declare(unit: lone, levels: [ { level_id: SecureRandom.uuid_v7, name: "Lane" } ], conversion: {})
      lane = structure.declared_structures[lone].kinds.sole.id
      error = assert_raises(ArgumentError) { as_tenant { @handler.remove_level(lane, structure_unit_id: lone, effective_on: @today) } }
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
        as_tenant { @handler.set_kind_parents(@squad, parent_ids: [], top: true, structure_unit_id: @payments, effective_on: @today) }
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
          add_level: -> { @handler.add_level(level_id, "Copy", parent_ids: [], top: true, structure_unit_id: named, effective_on: @today) },
          set_kind_parents: -> { @handler.set_kind_parents(level_id, parent_ids: [], top: true, structure_unit_id: named, effective_on: @today) },
          remove_level: -> { @handler.remove_level(level_id, structure_unit_id: named, effective_on: @today) }
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

  context "retiring a unit with a structure of its own" do
    setup do
      @lane = SecureRandom.uuid_v7
      @retire_on = @today + 5
    end

    should "withdraw the structure in the same change when an admin retires the unit" do
      declare(unit: @basket, levels: [ { level_id: @lane, name: "Lane" } ], conversion: {})
      event_store.with_metadata(correlation_id: "request-1") do
        as_tenant { @handler.retire_unit(@basket, effective_on: @retire_on) }
      end

      assert structure.unit(@basket).retired
      assert_empty structure.declared_structures
      assert_equal [ [], [ "Lane" ], "request-1" ],
                   last_definition.then { [ it[:levels], it[:previous_levels].map { |level| level[:name] }, last_event.metadata[:correlation_id] ] }
      assert_equal "request-1", event_store.read.of_type(OrgGraph::Events::UnitRetired).backward.first.metadata[:correlation_id]
      assert_equal [ { @basket => %w[Lane] }, {} ], [ @retire_on - 1, @retire_on ].map { structures_as_of(it) }
    end

    should "refuse an admin's retirement dated before the structure last changed" do
      declare(unit: @basket, levels: [ { level_id: @lane, name: "Lane" } ], conversion: {}, on: @today + 3)

      error = assert_raises(RuntimeError) { as_tenant { @handler.retire_unit(@basket, effective_on: @today + 1) } }
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

  private

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
    as_tenant { @handler.declare_structure(unit, levels:, conversion:, effective_on: on, **options) }
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
