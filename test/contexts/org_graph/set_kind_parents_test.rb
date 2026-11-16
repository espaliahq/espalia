# frozen_string_literal: true

require "test_helper"

class OrgGraph::SetKindParentsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @today = Date.current
    @tribe, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(@tribe, "Tribe", effective_on: @today)
      @handler.add_level(@squad, "Squad", parent_ids: [ @tribe ], top: false, effective_on: @today)
    end
    @payments = create_unit("Payments", @tribe)
  end

  should "add a kind with the parents and top it states" do
    assert_equal [ [ @tribe ], false ], rules(@squad)
    error = assert_raises(RuntimeError) { create_unit("Checkout", @squad) }
    assert_equal "Squad can't sit at the top", error.message
  end

  should "keep the derived rules for a kind added without parents" do
    guild = SecureRandom.uuid_v7
    as_tenant { @handler.add_level(guild, "Guild", effective_on: @today) }

    assert_nothing_raised { create_unit("Ledger", guild, parent_id: @payments) }
  end

  should "let a kind sit under its own kind once it lists itself" do
    checkout = create_unit("Checkout", @squad, parent_id: @payments)
    as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad ], top: false, effective_on: @today) }

    assert_equal [ [ @tribe, @squad ], false ], rules(@squad)
    assert_nothing_raised { create_unit("Basket", @squad, parent_id: checkout) }
  end

  should "refuse a list that leaves live units where their kind may not sit, naming them" do
    as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad ], top: false, effective_on: @today) }
    checkout = create_unit("Checkout", @squad, parent_id: @payments)
    create_unit("Basket", @squad, parent_id: checkout)

    error = assert_raises(RuntimeError) do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today) }
    end
    assert_equal "These units wouldn't fit this structure, so move them first: Basket (Squad under Squad)", error.message
  end

  should "refuse a kind that could sit nowhere" do
    error = assert_raises(ArgumentError) do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @squad ], top: false, effective_on: @today) }
    end
    assert_equal "A unit type needs somewhere to sit: under another type, or at the top", error.message
  end

  should "refuse a parent outside the taxonomy" do
    stranger = SecureRandom.uuid_v7
    error = assert_raises(ArgumentError) do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ stranger ], top: true, effective_on: @today) }
    end
    assert_equal "Not in the taxonomy: #{stranger}", error.message
  end

  should "refuse the rules of a kind an HRIS supplies" do
    @tenant = create(:tenant)
    department = SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(department, "Department", effective_on: @today)
      @handler.set_level_provider(department, "hibob", effective_on: @today, field: "department")
    end

    error = assert_raises(RuntimeError) do
      as_tenant { @handler.set_kind_parents(department, parent_ids: [ department ], top: true, effective_on: @today) }
    end
    assert_equal "Department comes from hibob, so its rules follow hibob", error.message
  end

  should "drop a removed kind from the lists that named it" do
    guild = SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(guild, "Guild", effective_on: @today)
      @handler.set_kind_parents(@squad, parent_ids: [ @tribe, guild ], top: false, effective_on: @today)
      @handler.remove_level(guild, effective_on: @today)
    end

    assert_equal [ [ @tribe ], false ], rules(@squad)
  end

  should "refuse to remove the only kind another kind can sit under" do
    pod = SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(pod, "Pod", effective_on: @today)
      @handler.set_kind_parents(@squad, parent_ids: [ pod ], top: false, effective_on: @today)
    end

    error = assert_raises(RuntimeError) { as_tenant { @handler.remove_level(pod, effective_on: @today) } }
    assert_equal "Squad would have nowhere to sit, so give it another place first", error.message
  end

  should "keep a kind that states its own rules from an HRIS until the HRIS rule is a list" do
    @tenant = create(:tenant)
    division = SecureRandom.uuid_v7
    as_tenant { @handler.add_level(division, "Division", parent_ids: [ division ], top: true, effective_on: @today) }

    error = assert_raises(RuntimeError) do
      as_tenant { @handler.set_level_provider(division, "hibob", effective_on: @today, field: "department") }
    end
    assert_equal "Division has its own rules for where it can sit, so it can't come from hibob yet", error.message
  end

  should "write nothing when the same rules are restated in another order" do
    as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @squad, @tribe ], top: false, effective_on: @today) }

    assert_no_difference -> { structure_events.size } do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad, @tribe ], top: false, effective_on: @today) }
    end
  end

  should "keep a kind with listed parents off the top unless told otherwise" do
    guild = SecureRandom.uuid_v7
    as_tenant { @handler.add_level(guild, "Guild", parent_ids: [ @tribe ], effective_on: @today) }

    assert_equal [ [ @tribe ], false ], rules(guild)
  end

  context "on a tenant whose kinds changed out of date order" do
    setup do
      @tenant = create(:tenant)
      @tribe, @guild = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" } ], on: "2026-11-14")
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" }, { level_id: @guild, name: "Guild" } ], on: "2026-10-01")
    end

    should "refuse a change dated before the latest kinds change, naming its date" do
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@guild, parent_ids: [ @tribe ], top: false, effective_on: "2026-11-13") }
      end
      assert_equal "The unit types last changed on 2026-11-14, so a change can't be dated before it", error.message
    end

    should "accept a change dated on or after the latest kinds change" do
      as_tenant { @handler.set_kind_parents(@guild, parent_ids: [ @tribe ], top: false, effective_on: @today) }

      assert_equal [ [ @tribe ], false ], rules(@guild)
    end
  end

  private

  def rules(level_id)
    as_tenant { OrgGraph::Repository.new.load_structure.taxonomy.kind(level_id) }.then { [ it.parent_ids, it.top ] }
  end

  def publish_taxonomy(levels, on:)
    Rails.configuration.event_store.publish(
      OrgGraph::Events::TaxonomyDefined.new(data: { levels:, previous_levels: [], effective_on: on, defined_by_id: nil },
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
