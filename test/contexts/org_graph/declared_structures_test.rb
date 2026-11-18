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

  private

  def structure = as_tenant { OrgGraph::Repository.new.load_structure }

  def publish_taxonomy(levels, unit_id: nil)
    data = { levels:, previous_levels: [], effective_on: @today.iso8601, defined_by_id: nil, structure_unit_id: unit_id }.compact
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

  def create_unit(name, level_id, parent_id: nil)
    unit_id = SecureRandom.uuid_v7
    as_tenant { @handler.create_unit(unit_id, name, level_id:, parent_id:, effective_on: @today) }
    unit_id
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
