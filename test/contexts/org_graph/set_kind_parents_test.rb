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

  should "drop a removed kind from the lists that named it" do
    guild = SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(guild, "Guild", effective_on: @today)
      @handler.set_kind_parents(@squad, parent_ids: [ @tribe, guild ], top: false, effective_on: @today)
      @handler.remove_level(guild, effective_on: @today)
    end

    assert_equal [ [ @tribe ], false ], rules(@squad)
  end

  should "refuse two kinds that may sit only under each other, since neither could have a first unit" do
    guild, chapter = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(guild, "Guild", effective_on: @today)
      @handler.add_level(chapter, "Chapter", effective_on: @today)
      @handler.set_kind_parents(guild, parent_ids: [ chapter ], top: false, effective_on: @today)
    end
    before = rules(chapter)

    error = assert_raises(RuntimeError) do
      as_tenant { @handler.set_kind_parents(chapter, parent_ids: [ guild, chapter ], top: false, effective_on: @today) }
    end
    assert_equal "Guild would have nowhere to sit, so give it another place first", error.message
    assert_equal before, rules(chapter)
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

  context "on a tenant whose top kinds an HRIS provides" do
    setup do
      @tenant = create(:tenant)
      @division, @department, @team = SecureRandom.uuid_v7, SecureRandom.uuid_v7, SecureRandom.uuid_v7
      as_tenant do
        @handler.add_level(@division, "Division", effective_on: @today)
        @handler.add_level(@department, "Department", effective_on: @today)
        @handler.add_level(@team, "Team", effective_on: @today)
        @handler.set_level_provider(@division, "hibob", effective_on: @today, field: "division")
        @handler.set_level_provider(@department, "hibob", effective_on: @today, field: "department")
      end
    end

    should "let a kind an HRIS provides list one HRIS kind above it, and the top" do
      as_tenant { @handler.set_kind_parents(@department, parent_ids: [ @division ], top: true, effective_on: @today) }

      assert_equal [ [ @division ], true ], rules(@department)
    end

    should "refuse an HRIS kind any other list, naming the HRIS" do
      [ [ [ @team ], true ], [ [ @department ], true ], [ [ @division ], false ], [ [ @division, @team ], true ] ].each do |parent_ids, top|
        error = assert_raises(RuntimeError) do
          as_tenant { @handler.set_kind_parents(@department, parent_ids:, top:, effective_on: @today) }
        end
        assert_equal "Department can sit only at the top, or under one type above it that an HRIS provides, " \
                     "while it comes from HiBob", error.message
      end
    end

    should "hand an HRIS a kind whose rules it can keep, and refuse one whose rules it can't" do
      as_tenant { @handler.set_kind_parents(@team, parent_ids: [ @team ], top: true, effective_on: @today) }
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_level_provider(@team, "hibob", effective_on: @today, field: "team") }
      end
      assert_equal "Team can sit only at the top, or under one type above it that an HRIS provides, while it comes from HiBob",
                   error.message

      as_tenant do
        @handler.set_kind_parents(@team, parent_ids: [ @department ], top: true, effective_on: @today)
        @handler.set_level_provider(@team, "hibob", effective_on: @today, field: "team")
      end
      assert_equal [ [ @department ], true ], rules(@team)
    end

    should "keep a kind with the HRIS while an HRIS kind lists it" do
      as_tenant { @handler.set_kind_parents(@department, parent_ids: [ @division ], top: true, effective_on: @today) }

      error = assert_raises(RuntimeError) { as_tenant { @handler.hand_back_level(@division, effective_on: @today) } }
      assert_equal "Division can't come back to Espalia while Department, which comes from HiBob, can sit under it", error.message
    end

    should "refuse a hand-over by field or by comparison when the HRIS can't keep the kind's rules" do
      as_tenant { @handler.set_kind_parents(@team, parent_ids: [ @team ], top: true, effective_on: @today) }

      [ -> { @handler.set_level_provider(@team, "hibob", effective_on: @today, field: "team") },
        -> { @handler.hand_over_level(@team, "hibob", field: "team", matches: {}, effective_on: @today) } ].each do |hand|
        error = assert_raises(RuntimeError) { as_tenant { hand.call } }
        assert_equal "Team can sit only at the top, or under one type above it that an HRIS provides, while it comes from HiBob",
                     error.message
      end
    end
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

  should "keep a kind added with only top: false off the top, under any kind above it" do
    guild = SecureRandom.uuid_v7
    as_tenant { @handler.add_level(guild, "Guild", top: false, effective_on: @today) }

    assert_equal [ [ @tribe, @squad ], false ], rules(guild)
  end

  should "refuse a change dated after today, pointing to a plan" do
    error = assert_raises(RuntimeError) do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad ], top: false, effective_on: @today + 1) }
    end
    assert_equal "A change to the unit types can't be dated after today. Date it today or earlier; plan a future structure in a plan",
                 error.message
  end

  context "on a tenant ahead of UTC, at 09:00 in Sydney" do
    setup do
      travel_to Time.utc(2026, 11, 16, 22)
      @tenant.update!(time_zone: "Australia/Sydney")
    end

    should "accept a change dated the tenant's today, a day ahead of UTC" do
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad ], top: false, effective_on: Date.new(2026, 11, 17)) }

      assert_equal [ [ @tribe, @squad ], false ], rules(@squad)
    end

    should "refuse a change dated the tenant's tomorrow" do
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad ], top: false, effective_on: Date.new(2026, 11, 18)) }
      end
      assert_match "can't be dated after today", error.message
    end
  end

  should "hold a change of a type's provider to the same dates" do
    @tenant = create(:tenant)
    division, department = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    as_tenant do
      @handler.add_level(division, "Division", effective_on: @today)
      @handler.add_level(department, "Department", effective_on: @today)
      @handler.set_level_provider(division, "hibob", effective_on: @today, field: "division")
    end

    { -> { @handler.set_level_provider(department, "hibob", effective_on: @today + 1, field: "department") } =>
        "A change to the unit types can't be dated after today. Date it today or earlier; plan a future structure in a plan",
      -> { @handler.hand_over_level(department, "hibob", field: "department", matches: {}, effective_on: @today + 1) } =>
        "A change to the unit types can't be dated after today. Date it today or earlier; plan a future structure in a plan",
      -> { @handler.hand_back_level(division, effective_on: @today - 1) } =>
        "The unit types last changed on #{@today.iso8601}, so a change can't be dated before it" }.each do |change, message|
      error = assert_raises(RuntimeError) { as_tenant { change.call } }
      assert_equal message, error.message
    end
  end

  context "on a tenant that already holds a future-dated kinds change" do
    setup do
      @tenant = create(:tenant)
      @tribe, @guild = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" } ], on: (@today - 10).iso8601)
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" }, { level_id: @guild, name: "Guild" } ], on: (@today + 30).iso8601)
    end

    should "compare a change only with the latest one dated today or earlier" do
      as_tenant { @handler.set_kind_parents(@guild, parent_ids: [ @tribe ], top: false, effective_on: @today) }
      assert_equal [ [ @tribe ], false ], rules(@guild)

      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@guild, parent_ids: [ @tribe, @guild ], top: false, effective_on: @today - 11) }
      end
      assert_equal "The unit types last changed on #{@today.iso8601}, so a change can't be dated before it", error.message
    end
  end

  context "on a tenant whose Squads may nest only from today" do
    setup do
      @tenant = create(:tenant)
      @tribe, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" }, { level_id: @squad, name: "Squad", parent_level_ids: [ @tribe ], top: false } ],
                       on: (@today - 10).iso8601)
      @payments = create_unit("Payments", @tribe, on: @today - 10)
      @checkout = create_unit("Checkout", @squad, parent_id: @payments, on: @today - 10)
      @basket = create_unit("Basket", @squad, parent_id: @payments, on: @today - 10)
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe, @squad ], top: false, effective_on: @today) }
    end

    should "refuse a move dated before the rule that allows it, naming the day" do
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.move_unit(@basket, @checkout, effective_on: @today - 1) }
      end
      assert_equal "On #{(@today - 1).iso8601}, Squad couldn't sit under Squad, so the change can't be dated before its rules allowed it",
                   error.message
    end

    should "accept the same move dated from the rule's day" do
      assert_nothing_raised { as_tenant { @handler.move_unit(@basket, @checkout, effective_on: @today) } }
    end

    should "accept a unit dated before its kind existed, as an HRIS backfill does" do
      guild = SecureRandom.uuid_v7
      as_tenant { @handler.add_level(guild, "Guild", effective_on: @today) }

      assert_nothing_raised { create_unit("Ledger", guild, on: @today - 30) }
    end
  end

  context "on a tenant whose Basket sat under another Squad until three days ago" do
    setup do
      @tenant = create(:tenant)
      @tribe, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" },
                         { level_id: @squad, name: "Squad", parent_level_ids: [ @tribe, @squad ], top: false } ],
                       on: (@today - 10).iso8601)
      @payments = create_unit("Payments", @tribe, on: @today - 10)
      @checkout = create_unit("Checkout", @squad, parent_id: @payments, on: @today - 10)
      @basket = create_unit("Basket", @squad, parent_id: @checkout, on: @today - 10)
    end

    should "refuse to stop Squads nesting from before the Basket moved, naming when it did" do
      as_tenant { @handler.move_unit(@basket, @payments, effective_on: @today - 3) }

      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today - 5) }
      end
      assert_equal "These units sat where this structure wouldn't allow after #{(@today - 5).iso8601}, " \
                   "so date it #{(@today - 3).iso8601} or later: Basket (Squad under Squad until #{(@today - 3).iso8601})",
                   error.message
    end

    should "refuse the same change while a retired Basket still sat under Checkout" do
      as_tenant { @handler.retire_unit(@basket, effective_on: @today - 3) }

      assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today - 5) }
      end
    end

    should "count a retired Basket under Checkout on its retirement day, and accept the change from the day after" do
      as_tenant { @handler.retire_unit(@basket, effective_on: @today - 3) }

      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today - 3) }
      end
      assert_equal "These units sat where this structure wouldn't allow after #{(@today - 3).iso8601}, " \
                   "so date it #{(@today - 2).iso8601} or later: Basket (Squad under Squad until #{(@today - 2).iso8601})",
                   error.message

      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today - 2) }
      assert_equal [ [ @tribe ], false ], rules(@squad)
    end

    should "accept the change dated from the day the Basket moved" do
      as_tenant { @handler.move_unit(@basket, @payments, effective_on: @today - 3) }
      as_tenant { @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today - 3) }

      assert_equal [ [ @tribe ], false ], rules(@squad)
    end
  end

  context "on a tenant whose Squads could nest until two days ago" do
    setup do
      @tenant = create(:tenant)
      @tribe, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      publish_taxonomy([ { level_id: @tribe, name: "Tribe" },
                         { level_id: @squad, name: "Squad", parent_level_ids: [ @tribe, @squad ], top: false } ],
                       on: (@today - 10).iso8601)
      @payments = create_unit("Payments", @tribe, on: @today - 10)
      @orders = create_unit("Orders", @tribe, on: @today - 10)
      @checkout = create_unit("Checkout", @squad, parent_id: @payments, on: @today - 10)
      @basket = create_unit("Basket", @squad, parent_id: @payments, on: @today - 10)
      as_tenant do
        @handler.move_unit(@basket, @orders, effective_on: @today - 4)
        @handler.set_kind_parents(@squad, parent_ids: [ @tribe ], top: false, effective_on: @today - 2)
      end
    end

    should "accept a move under a Squad that ends before Squads stopped nesting" do
      as_tenant { @handler.move_unit(@basket, @checkout, effective_on: @today - 6) }

      moved = Rails.configuration.event_store.read.of_type(OrgGraph::Events::UnitMoved).last.data
      assert_equal [ @basket, @checkout, (@today - 6).iso8601 ], moved.values_at(:unit_id, :parent_id, :effective_on)
    end

    should "keep the Basket under Orders today, as the later move still holds" do
      as_tenant { @handler.move_unit(@basket, @checkout, effective_on: @today - 6) }

      assert_equal @orders, as_tenant { OrgGraph::Repository.new.load_structure.unit(@basket).parent_id }
      moved = Rails.configuration.event_store.read.of_type(OrgGraph::Events::UnitMoved).last.data
      assert_equal @payments, moved[:previous_parent_id]
    end

    should "record a past move back under Orders, though Orders is the Basket's parent today" do
      as_tenant do
        @handler.move_unit(@basket, @checkout, effective_on: @today - 6)
        @handler.move_unit(@basket, @orders, effective_on: @today - 5)
      end

      moved = Rails.configuration.event_store.read.of_type(OrgGraph::Events::UnitMoved).last.data
      assert_equal [ @orders, @checkout, (@today - 5).iso8601 ], moved.values_at(:parent_id, :previous_parent_id, :effective_on)
      assert_equal @orders, as_tenant { OrgGraph::Repository.new.load_structure.unit(@basket).parent_id }
    end

    should "still refuse a move under a Squad that holds into today" do
      error = assert_raises(RuntimeError) { as_tenant { @handler.move_unit(@basket, @checkout, effective_on: @today - 1) } }
      assert_equal "Squad can't sit under Squad", error.message
    end
  end

  context "on a tenant whose retired Ledger sat under a Division until three days ago" do
    setup do
      @tenant = create(:tenant)
      @division, @department, @team = Array.new(3) { SecureRandom.uuid_v7 }
      as_tenant do
        [ [ @division, "Division" ], [ @department, "Department" ], [ @team, "Team" ] ].each do |id, name|
          @handler.add_level(id, name, effective_on: @today - 10)
        end
        @handler.set_level_provider(@division, "hibob", effective_on: @today - 10, field: "division")
        @handler.set_level_provider(@department, "hibob", effective_on: @today - 10, field: "department")
        @org = SecureRandom.uuid_v7
        @handler.create_unit(@org, "Org", level_id: @division, provider: "hibob", external_ref: "d1", effective_on: @today - 10)
      end
      @ledger = create_unit("Ledger", @team, parent_id: @org, on: @today - 10)
      as_tenant { @handler.retire_unit(@ledger, effective_on: @today - 3) }
    end

    should "refuse to hand Team to the HRIS from before the Ledger retired, naming when it left" do
      error = assert_raises(RuntimeError) do
        as_tenant { @handler.set_level_provider(@team, "hibob", effective_on: @today - 5, field: "team") }
      end
      assert_equal "These units sat where this structure wouldn't allow after #{(@today - 5).iso8601}, " \
                   "so date it #{(@today - 2).iso8601} or later: Ledger (Team under Division until #{(@today - 2).iso8601})",
                   error.message
    end

    should "hand Team to the HRIS from the day after the Ledger retired" do
      as_tenant { @handler.set_level_provider(@team, "hibob", effective_on: @today - 2, field: "team") }

      assert_equal "hibob", as_tenant { OrgTaxonomyLevel.find(@team).provider }
    end
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

  def create_unit(name, level_id, parent_id: nil, on: @today)
    unit_id = SecureRandom.uuid_v7
    as_tenant { @handler.create_unit(unit_id, name, level_id:, parent_id:, effective_on: on) }
    unit_id
  end

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
