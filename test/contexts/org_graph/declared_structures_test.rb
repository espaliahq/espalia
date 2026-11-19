# frozen_string_literal: true

require "test_helper"

# Nothing writes a declared structure until #494's declaring commands land, so
# each test publishes the events and reads what the aggregate makes of them.
class OrgGraph::DeclaredStructuresTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @today = Date.new(2026, 11, 1)
    @tribe, @squad, @group, @stream = Array.new(4) { SecureRandom.uuid_v7 }
    publish_taxonomy([ { level_id: @tribe, name: "Tribe", parent_level_ids: [], top: true },
                       { level_id: @squad, name: "Squad", parent_level_ids: [ @tribe, @squad ], top: false } ])
    @payments = create_unit("Payments", @tribe)
    @checkout = create_unit("Checkout", @squad, parent_id: @payments)
    @basket = create_unit("Basket", @squad, parent_id: @checkout)
    publish_taxonomy([ { level_id: @group, name: "Group", parent_level_ids: [], top: true },
                       { level_id: @stream, name: "Stream", parent_level_ids: [ @group ], top: false } ], unit_id: @payments)
  end

  should "govern every unit beneath the declaring unit, and not the declaring unit itself" do
    assert_nil structure.structure_in_force(@payments)
    assert_equal [ @payments, @payments ], [ @checkout, @basket ].map { structure.structure_in_force(it) }
    assert_equal %w[Group Stream], structure.taxonomy_for(@basket).kinds.map(&:name)
    assert_equal %w[Tribe Squad], structure.taxonomy_for(@payments).kinds.map(&:name)
  end

  should "judge each unit by the structure in force where it sits, with the declaring unit as its top" do
    assert_equal %w[Basket Checkout], structure.misplaced_units.map(&:name)

    change_kind(@checkout, @squad, @group)
    change_kind(@basket, @squad, @stream)
    assert_empty structure.misplaced_units
  end

  should "let a nested structure take over below its unit, and its parent structure stop there" do
    lane = SecureRandom.uuid_v7
    change_kind(@checkout, @squad, @group)
    change_kind(@basket, @squad, @stream)
    publish_taxonomy([ { level_id: lane, name: "Lane", parent_level_ids: [], top: true } ], unit_id: @checkout)

    assert_equal [ @payments, @checkout ], [ @checkout, @basket ].map { structure.structure_in_force(it) }
    assert_equal %w[Basket], structure.misplaced_units.map(&:name)
  end

  should "stop governing once withdrawn" do
    publish_taxonomy([], unit_id: @payments)

    assert_nil structure.structure_in_force(@basket)
    assert_empty structure.declared_structures
    assert_empty structure.misplaced_units
  end

  should "leave a declared structure alone when the top structure is redefined" do
    as_tenant do
      @handler.define_taxonomy([ { level_id: @tribe, name: "Tribe of teams" }, { level_id: @squad, name: "Squad" } ], effective_on: @today)
    end

    assert_equal %w[Tribe\ of\ teams Squad], structure.taxonomy.kinds.map(&:name)
    assert_equal({ @payments => %w[Group Stream] }, structure.declared_structures.transform_values { it.kinds.map(&:name) })
    assert_equal %w[Tribe\ of\ teams Squad], as_tenant { OrgTaxonomyLevel.top_structure.pluck(:name) }
  end

  context "placing a unit" do
    setup do
      change_kind(@checkout, @squad, @group)
      change_kind(@basket, @squad, @stream)
    end

    should "seat a unit beneath the declaring unit at the top of its structure, by that structure's types" do
      lane = create_unit("Lane", @group, parent_id: @payments)
      ramp = create_unit("Ramp", @stream, parent_id: lane)

      assert_equal [ @payments, @payments ], [ lane, ramp ].map { structure.structure_in_force(it) }
      assert_empty structure.misplaced_units
    end

    should "refuse a top structure type beneath the declaring unit, and a declared type outside its structure" do
      error = assert_raises(RuntimeError) { create_unit("Squad A", @squad, parent_id: @payments) }
      assert_equal "Squad isn't a unit type of Payments's structure", error.message

      error = assert_raises(RuntimeError) { create_unit("Loose", @group) }
      assert_equal "Group isn't a unit type of the organisation's structure", error.message
    end

    should "refuse a type of the structure where its rules don't allow it" do
      error = assert_raises(RuntimeError) { create_unit("Ramp", @stream, parent_id: @payments) }
      assert_equal "Stream can't sit at the top of Payments's structure", error.message
    end

    should "refuse a change dated before the structure began" do
      lane = SecureRandom.uuid_v7
      publish_taxonomy([ { level_id: lane, name: "Lane", parent_level_ids: [], top: true } ], unit_id: @checkout, on: @today + 1)

      error = assert_raises(RuntimeError) { create_unit("Fast lane", lane, parent_id: @checkout) }
      assert_equal "Checkout's structure last changed on #{(@today + 1).iso8601}, so date the change then or later", error.message
    end

    should "refuse a move out of the structure, and one into it" do
      other = create_unit("Lending", @tribe)
      error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(@checkout, other, effective_on: @today) } }
      assert_equal "Checkout can't move out of Payments's structure into the organisation's structure", error.message

      squad = create_unit("Squad A", @squad, parent_id: other)
      error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(squad, @checkout, effective_on: @today) } }
      assert_equal "Squad A can't move out of the organisation's structure into Payments's structure", error.message
    end

    should "move a unit within its structure" do
      lane = create_unit("Lane", @group, parent_id: @payments)
      as_tenant { @handler.move_unit(@basket, lane, effective_on: @today) }

      assert_equal lane, structure.unit(@basket).parent_id
    end

    should "change a unit's type only to one of its own structure, judged by that structure's rules" do
      error = assert_raises(RuntimeError) { as_tenant { @handler.change_unit_kind(@basket, @squad, effective_on: @today) } }
      assert_equal "Squad isn't a unit type of Payments's structure", error.message

      error = assert_raises(RuntimeError) { as_tenant { @handler.change_unit_kind(@basket, @group, effective_on: @today) } }
      assert_equal "Basket can't change to Group, as these wouldn't fit: Basket under Checkout (Group)", error.message
    end

    should "not judge the declaring unit's sub-units by its own type" do
      tribe_two = SecureRandom.uuid_v7
      as_tenant { @handler.add_level(tribe_two, "Tribe of tribes", parent_ids: [], top: true, effective_on: @today) }
      as_tenant { @handler.change_unit_kind(@payments, tribe_two, effective_on: @today) }

      assert_equal tribe_two, structure.unit(@payments).level_id
      assert_empty structure.misplaced_units
    end

    should "refuse a merge across structures, and split one within a structure" do
      other = create_unit("Lending", @tribe)
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @basket ], successor_ids: [ other ], effective_on: @today) }
      end
      assert_equal "A merge or split can't cross structures: these units sit in Payments's structure and the organisation's structure", error.message

      ramp = create_unit("Ramp", @stream, parent_id: @checkout)
      as_tenant do
        @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @basket ], successor_ids: [ ramp ], effective_on: @today,
                                                         retire_predecessors: true)
      end
      assert structure.unit(@basket).retired
    end

    should "leave declared units out when the top structure's rules narrow" do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today) }

      assert_equal [ @tribe ], structure.taxonomy.kind(@squad).parent_ids
    end
  end

  private

  def structure = as_tenant { OrgGraph::Repository.new.load_structure }

  def publish_taxonomy(levels, unit_id: nil, on: @today)
    data = { levels:, previous_levels: [], effective_on: on.iso8601, defined_by_id: nil, structure_unit_id: unit_id }.compact
    publish(OrgGraph::Events::TaxonomyDefined.new(data:, metadata: { tenant_id: @tenant.id }))
  end

  def change_kind(unit_id, from, to)
    publish(OrgGraph::Events::UnitKindChanged.new(
      data: { unit_id:, level_id: to, previous_level_id: from, provider: "espalia", effective_on: @today.iso8601 },
      metadata: { tenant_id: @tenant.id }
    ))
  end

  def publish(event)
    Rails.configuration.event_store.publish(event, stream_name: as_tenant { EventStreamNaming.org_structure_stream })
  end

  def create_unit(name, level_id, parent_id: nil, on: @today)
    unit_id = SecureRandom.uuid_v7
    as_tenant { @handler.create_unit(unit_id, name, level_id:, parent_id:, effective_on: on) }
    unit_id
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
