# frozen_string_literal: true

require "test_helper"
require_relative "../../support/rebuild_lock"

class OrgGraph::MoveIntoStructureTest < ActiveSupport::TestCase
  include RebuildLock

  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @system = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @admin = OrgGraph::StructureCommandHandler.new(actor: admin_context)
    @today = Date.new(2026, 11, 1)
    travel_to Time.zone.parse("2026-11-10 09:00")
    @tribe, @squad, @pod, @region, @group, @stream = Array.new(6) { SecureRandom.uuid_v7 }
    as_tenant do
      @system.define_taxonomy([ { level_id: @region, name: "Region" }, { level_id: @tribe, name: "Tribe" }, { level_id: @squad, name: "Squad" },
                                { level_id: @pod, name: "Pod" } ],
                              effective_on: @today)
    end
    @payments = create_unit("Payments", @tribe)
    @core = create_unit("Core", @tribe)
    @ledger = create_unit("Ledger", @squad, parent_id: @core)
    @till = create_unit("Till", @pod, parent_id: @ledger)
    as_tenant { @admin.declare_structure(@payments, levels: groups_and_streams, conversion: {}, effective_on: @today + 1) }
  end

  should "move a team into a unit's own structure, converting it and the units beneath it in one change" do
    as_tenant do
      @ada = create(:person, tenant: @tenant)
      @people = OrgGraph::CommandHandler.new(actor: SYSTEM)
      @people.record_person(@ada.id, provider: "espalia", effective_on: @today.iso8601, employment_status: "employed")
      @people.set_membership(@ada.id, @till, provider: "espalia", effective_on: @today.iso8601, allocation: 1.0)
      @system.add_unit_owner(@ledger, @ada.id, effective_on: @today)
    end
    history = as_tenant { [ @ledger, @till ].to_h { [ it, OrgUnitActivity.for_unit(it).pluck(:event_id) ] } }

    Rails.configuration.event_store.with_metadata(correlation_id: "request-1") { move_in }

    assert_equal [ @payments, @payments ], [ @ledger, @till ].map { structure.structure_in_force(it) }
    assert_equal [ @group, @stream ], [ @ledger, @till ].map { structure.unit(it).level_id }
    assert_equal [ @payments, @ledger ], [ @ledger, @till ].map { structure.unit(it).parent_id }
    assert_empty structure.misplaced_units

    moved = event_store.read.of_type(OrgGraph::Events::UnitMoved).backward.first
    assert_equal({ @squad => @group, @pod => @stream }, moved.data[:conversion])
    kinds = event_store.read.of_type(OrgGraph::Events::UnitKindChanged).to_a
    assert_equal [ "request-1" ] * 3, [ moved, *kinds ].map { it.metadata[:correlation_id] }

    as_tenant do
      assert_equal [ @ada.id ], OrgUnit.find(@ledger).owners.map(&:id)
      assert_equal [ @ada.id ], OrgMembership.where(unit_id: @till).pluck(:person_id)
      history.each { |unit, ids| assert_equal ids, OrgUnitActivity.for_unit(unit).pluck(:event_id).last(ids.size) }
    end
  end

  should "date a move no earlier than the day an HRIS handed its units back" do
    as_tenant do
      matches = { @region => {}, @tribe => { @payments => "t-1", @core => "t-2" }, @squad => { @ledger => "s-1" }, @pod => { @till => "p-1" } }
      matches.each { |level, units| @admin.hand_over_level(level, "hibob", field: "work.#{level}", matches: units, effective_on: @today + 2) }
      matches.keys.reverse_each { @admin.hand_back_level(it, effective_on: @today + 4) }
    end

    error = assert_raises(RuntimeError) { move_in(on: @today + 3) }
    assert_equal "Till changed on #{@today + 4}, so date the move then or later", error.message

    move_in(on: @today + 4)
    assert_equal @stream, structure.unit(@till).level_id
  end

  should "refuse a conversion on a move that crosses no structure" do
    error = assert_raises(RuntimeError) { as_tenant { @admin.move_unit(@ledger, @core, effective_on: @today, conversion: {}) } }
    assert_equal "Ledger stays in the top structure, so the move takes no conversion", error.message

    lending = create_unit("Lending", @squad, parent_id: @core)
    error = assert_raises(RuntimeError) { as_tenant { @admin.move_unit(lending, @ledger, effective_on: @today, conversion: {}) } }
    assert_equal "Lending stays in the top structure, so the move takes no conversion", error.message
  end

  should "refuse a move out of a structure" do
    move_in
    error = assert_raises(RuntimeError) { as_tenant { @admin.move_unit(@ledger, @core, effective_on: @today + 1, conversion: {}) } }
    assert_equal "Ledger can't move out of Payments's structure yet", error.message
  end

  should "refuse a subtree holding a unit with a structure of its own" do
    lane = SecureRandom.uuid_v7
    as_tenant do
      @admin.declare_structure(@ledger, levels: [ { level_id: lane, name: "Lane", parent_level_ids: [], top: true } ],
                                        conversion: { @pod => lane }, effective_on: @today + 1)
    end
    error = assert_raises(RuntimeError) { move_in(unit: @core, conversion: { @tribe => @group }) }
    assert_equal "Ledger has a structure of its own, so it can't move into Payments's structure yet", error.message
  end

  should "refuse a unit that wouldn't fit, or a held type the conversion leaves out" do
    error = assert_raises(RuntimeError) { move_in(conversion: { @squad => @stream, @pod => @stream }) }
    assert_equal "These units wouldn't fit Payments's structure: Ledger (Stream at the top), Till (Stream under Stream)", error.message

    error = assert_raises(RuntimeError) { move_in(conversion: { @squad => @group }) }
    assert_equal "Say what Pod units become", error.message
    assert_nil structure.structure_in_force(@ledger)
  end

  should "refuse two spellings of one type that map to different types" do
    error = assert_raises(ArgumentError) { move_in(conversion: { @squad.upcase => @group, @squad => @stream, @pod => @stream }) }
    assert_equal "The conversion says two things Squad units become", error.message
    assert_nil structure.structure_in_force(@ledger)
  end

  should "fit a moved unit to the type its new parent holds, whatever the conversion maps that type to" do
    cards = create_unit("Cards", @group, parent_id: @payments, on: @today + 1)
    wallet = create_unit("Wallet", @stream, parent_id: cards, on: @today + 1)
    lending = create_unit("Lending", @squad, parent_id: @core)

    error = assert_raises(RuntimeError) { move_in(unit: lending, parent_id: wallet, conversion: { @squad => @stream, @stream => @group }) }
    assert_equal "These units wouldn't fit Payments's structure: Lending (Stream under Stream)", error.message

    move_in(unit: lending, parent_id: cards, conversion: { @squad => @stream, @stream => @group })
    assert_equal [ cards, @stream ], [ structure.unit(lending).parent_id, structure.unit(lending).level_id ]
  end

  should "date the move no earlier than the structure's last change or a change beneath, and no later than today" do
    error = assert_raises(RuntimeError) { move_in(on: @today) }
    assert_equal "Payments's structure last changed on #{(@today + 1).iso8601}, so date the change then or later", error.message

    create_unit("Basket", @pod, parent_id: @ledger, on: @today + 3)
    error = assert_raises(RuntimeError) { move_in(on: @today + 2) }
    assert_equal "Basket changed on #{(@today + 3).iso8601}, so date the move then or later", error.message

    error = assert_raises(RuntimeError) { move_in(on: Date.new(2026, 11, 11)) }
    assert_equal "A move into a structure can't be dated after today", error.message

    move_in(on: @today + 3)
    assert_equal @payments, structure.structure_in_force(@ledger)
  end

  should "allow a move dated the day the structure last changed" do
    move_in(on: @today + 1)
    assert_equal @group, structure.unit(@ledger).level_id
  end

  should "refuse a change beneath a moved unit dated before it arrived" do
    move_in(on: @today + 3)

    error = assert_raises(RuntimeError) { create_unit("Basket", @stream, parent_id: @ledger, on: @today + 2) }
    assert_equal "Payments's structure last changed on #{(@today + 3).iso8601}, so date the change then or later", error.message
    basket = create_unit("Basket", @stream, parent_id: @ledger, on: @today + 3)
    assert_equal @payments, structure.structure_in_force(basket)
  end

  should "refuse a unit from an HRIS" do
    hris = SecureRandom.uuid_v7
    as_tenant do
      @system.set_level_provider(@region, "hibob", field: "work.region", effective_on: @today)
      @system.create_unit(hris, "Imported", level_id: @region, effective_on: @today, provider: "hibob", external_ref: "r-1")
    end
    error = assert_raises(RuntimeError) { move_in(unit: hris, conversion: { @region => @group }) }
    assert_equal "hibob supplies this unit; change it there", error.message

    error = assert_raises(RuntimeError) do
      as_tenant { @admin.move_unit(hris, @payments, effective_on: @today + 1, provider: "hibob", conversion: { @region => @group }) }
    end
    assert_equal "hibob supplies Imported, so it can't move into Payments's structure", error.message
    assert_equal @region, structure.unit(hris).level_id
  end

  should "refuse an owner of both units who may not change the structure, before any check of the move" do
    owner = as_tenant do
      person = create(:person, tenant: @tenant)
      OrgGraph::CommandHandler.new(actor: SYSTEM).record_person(person.id, provider: "espalia", effective_on: @today.iso8601,
                                                                           employment_status: "employed")
      [ @core, @payments ].each { @system.add_unit_owner(it, person.id, effective_on: @today) }
      tenant_user = create(:tenant_user, tenant: @tenant, role: :member, person:)
      OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: tenant_user.user, tenant_user:, person:))
    end

    error = assert_raises(OrgGraph::Authorization::Refused) do
      as_tenant { owner.move_unit(@ledger, @payments, effective_on: @today + 1, conversion: { @squad => @stream }) }
    end
    assert_equal "Only a tenant admin can move a unit into a unit's own structure", error.message
    assert_nil structure.structure_in_force(@ledger)
    error = assert_raises(RuntimeError) { as_tenant { owner.move_unit(@ledger, @payments, effective_on: @today + 1) } }
    assert_equal "Ledger can't move out of the top structure into Payments's structure", error.message

    error = assert_raises(OrgGraph::Authorization::Refused) { as_tenant { @system.move_unit(@ledger, @payments, effective_on: @today + 1, conversion: {}) } }
    assert_equal "Only a tenant admin can move a unit into a unit's own structure", error.message
  end

  should "refuse a move into a structure while the kinds are rebuilt, telling only a caller who may make it" do
    [ OrgGraph::Projections::History, OrgGraph::Projections::Structure ].each do |projection|
      while_rebuilding(@tenant, projection) do
        assert_raises(ProjectionVersion::Rebuilding) { move_in }
        assert_raises(OrgGraph::Authorization::Refused) do
          as_tenant { @system.move_unit(@ledger, @payments, effective_on: @today + 1, conversion: { @squad => @group, @pod => @stream }) }
        end
      end
    end
    assert_nil structure.structure_in_force(@ledger)
  end

  should "share one cause outside a request, and refuse to change any part of it back" do
    move_in
    as_tenant do
      cause_id = OrgUnitActivity.find_by!(unit_id: @ledger, event_type: "UnitMoved").cause_id
      entries = OrgUnitActivity.where(cause_id:).to_a
      assert_equal [ [ @ledger, "UnitKindChanged" ], [ @ledger, "UnitMoved" ], [ @till, "UnitKindChanged" ] ].sort,
                   entries.map { [ it.unit_id, it.event_type ] }.uniq.sort
      change_back = OrgGraph::ChangeBackHandler.new(actor: SYSTEM)
      entries.each do |entry|
        error = assert_raises(RuntimeError) { change_back.change_back(entry) }
        assert_equal OrgGraph::ChangeBackHandler::MOVED_IN, error.message
      end
      assert_equal OrgGraph::ChangeBackHandler::MOVED_IN, change_back.group_refusal(cause_id)
    end
  end

  context "removing a tenant-wide type" do
    should "allow it once every holder has retired, dated after the last retirement" do
      north = create_unit("North", @region)
      as_tenant { @admin.retire_unit(north, effective_on: @today + 2) }

      error = assert_raises(RuntimeError) { remove_level(@region, on: @today + 2) }
      assert_equal "North was a Region until #{(@today + 2).iso8601}, so date its removal after then", error.message

      remove_level(@region, on: @today + 3)
      assert_nil structure.taxonomy.kind(@region)
    end

    should "not count a retired unit left beneath a moved-in team as still holding its type" do
      basket = create_unit("Basket", @pod, parent_id: @ledger)
      as_tenant { @admin.retire_unit(basket, effective_on: @today + 1) }
      move_in(on: @today + 2)
      assert_equal @pod, structure.unit(basket).level_id

      error = assert_raises(RuntimeError) { remove_level(@pod, on: @today + 1) }
      assert_match(/ was a Pod until #{(@today + 1).iso8601}, so date its removal after then\z/, error.message)

      remove_level(@pod, on: @today + 2)
      assert_nil structure.taxonomy.kind(@pod)
    end

    should "refuse it while a live unit still holds it" do
      error = assert_raises(RuntimeError) { remove_level(@tribe, on: @today + 3) }
      assert_equal "Tribe can't be removed, as it holds Core and Payments", error.message
    end
  end

  should "replay a move written before moves took a conversion as it always read" do
    lending = create_unit("Lending", @tribe)
    as_tenant { @system.move_unit(@ledger, lending, effective_on: @today + 1) }
    moved = event_store.read.of_type(OrgGraph::Events::UnitMoved).backward.first
    assert_not moved.data.key?(:conversion)
    assert_nil structure.structure_in_force(@ledger)
    assert_equal @squad, structure.unit(@ledger).level_id
    as_tenant { assert_equal({ "parent_id" => moved.data[:parent_id] }, OrgUnitActivity.for_unit(@ledger).first.after) }
  end

  private

  def move_in(unit: @ledger, parent_id: @payments, conversion: { @squad => @group, @pod => @stream }, on: @today + 1)
    as_tenant { @admin.move_unit(unit, parent_id, effective_on: on, conversion:) }
  end

  def remove_level(level_id, on:)
    as_tenant { @admin.remove_level(level_id, effective_on: on) }
  end

  def groups_and_streams
    [ { level_id: @group, name: "Group", parent_level_ids: [], top: true },
      { level_id: @stream, name: "Stream", parent_level_ids: [ @group ], top: false } ]
  end

  def admin_context
    as_tenant do
      tenant_user = create(:tenant_user, tenant: @tenant, role: :admin)
      AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil)
    end
  end

  def event_store = Rails.configuration.event_store

  def structure = as_tenant { OrgGraph::Repository.new.load_structure }

  def create_unit(name, level_id, parent_id: nil, on: @today)
    unit_id = SecureRandom.uuid_v7
    as_tenant { @system.create_unit(unit_id, name, level_id:, parent_id:, effective_on: on) }
    unit_id
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
