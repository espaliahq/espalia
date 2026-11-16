# frozen_string_literal: true

require "test_helper"

# No command writes a kind's rules yet, so each test publishes the
# TaxonomyDefined a later command will write.
class OrgGraph::StatedKindRulesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @tribe, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @today = Date.new(2026, 11, 1)
    define_rules(tribe: { parent_level_ids: [], top: true }, squad: { parent_level_ids: [ @tribe, @squad ], top: false })
    @payments = create_unit("Payments", @tribe)
  end

  should "let a kind sit beneath its own kind when it lists itself" do
    checkout = create_unit("Checkout", @squad, parent_id: @payments)

    assert_nothing_raised { create_unit("Basket", @squad, parent_id: checkout) }
  end

  should "refuse a parent of a kind the unit's kind doesn't list" do
    other = create_unit("Lending", @tribe)

    error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(other, @payments, effective_on: @today) } }
    assert_equal "A parent must sit at a higher level", error.message
  end

  should "refuse the top to a kind that may not sit there" do
    error = assert_raises(RuntimeError) { create_unit("Checkout", @squad) }
    assert_equal "Squad can't sit at the top", error.message
  end

  should "refuse to move a unit beneath itself or a unit below it" do
    checkout = create_unit("Checkout", @squad, parent_id: @payments)
    basket = create_unit("Basket", @squad, parent_id: checkout)

    [ checkout, basket ].each do |parent_id|
      error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(checkout, parent_id, effective_on: @today) } }
      assert_equal "A unit can't move beneath itself or a unit below it", error.message
    end
  end

  should "retire the deepest units first when kinds no longer set the order" do
    checkout = create_unit("Checkout", @squad, parent_id: @payments)
    basket = create_unit("Basket", @squad, parent_id: checkout)
    successor = create_unit("Lending", @tribe)

    as_tenant do
      @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ checkout, basket, @payments ], successor_ids: [ successor ],
                                 effective_on: @today, retire_predecessors: true)
    end

    retired = structure_events.grep(OrgGraph::Events::UnitRetired).map { |event| event.data[:unit_id] }
    assert_equal [ basket, checkout, @payments ], retired
  end

  should "name the live units a change of rules leaves where their kind may not sit" do
    checkout = create_unit("Checkout", @squad, parent_id: @payments)
    create_unit("Basket", @squad, parent_id: checkout)
    define_rules(tribe: { parent_level_ids: [], top: false }, squad: { parent_level_ids: [ @tribe ], top: false })

    assert_equal %w[Basket Payments], as_tenant { OrgGraph::Repository.new.load_structure.misplaced_units.map(&:name) }
  end

  should "keep each kind's stated rules when a kind is added or removed around it" do
    stated = ->(level_id) { as_tenant { OrgGraph::Repository.new.load_structure.taxonomy.kind(level_id) }.then { [ it.parent_ids, it.top ] } }
    guild = SecureRandom.uuid_v7

    as_tenant { @handler.add_level(guild, "Guild", effective_on: @today) }
    assert_equal [ [ @tribe, @squad ], false ], stated.(@squad)
    assert_equal [ [], true ], stated.(@tribe)

    as_tenant { @handler.remove_level(guild, effective_on: @today) }
    assert_equal [ [ @tribe, @squad ], false ], stated.(@squad)
  end

  private

  def define_rules(tribe:, squad:)
    levels = [ { level_id: @tribe, name: "Tribe", **tribe }, { level_id: @squad, name: "Squad", **squad } ]
    Rails.configuration.event_store.publish(
      OrgGraph::Events::TaxonomyDefined.new(data: { levels:, previous_levels: [], effective_on: @today.iso8601, defined_by_id: nil },
                                            metadata: { tenant_id: @tenant.id }),
      stream_name: as_tenant { EventStreamNaming.org_structure_stream }
    )
  end

  def create_unit(name, level_id, parent_id: nil)
    unit_id = SecureRandom.uuid_v7
    as_tenant { @handler.create_unit(unit_id, name, level_id:, parent_id:, effective_on: @today) }
    unit_id
  end

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
