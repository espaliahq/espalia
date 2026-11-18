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

    error = assert_raises(RuntimeError) { declare(on: @today - 1) }
    assert_equal "Checkout changed on #{@today.iso8601}, so date this then or later", error.message

    declare
    error = assert_raises(RuntimeError) { declare(levels: [ { level_id: SecureRandom.uuid_v7, name: "Lane" } ]) }
    assert_equal "Payments already has its own structure", error.message
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

  private

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
