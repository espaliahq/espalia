# frozen_string_literal: true

require "test_helper"

class OrgGraph::MoveOutOfStructureTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @system = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @admin_context = as_tenant do
      tenant_user = create(:tenant_user, tenant: @tenant, role: :admin)
      AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil)
    end
    @admin = OrgGraph::StructureCommandHandler.new(actor: @admin_context)
    @today = Date.new(2026, 11, 1)
    travel_to Time.zone.parse("2026-11-10 09:00")
    @tribe, @squad, @pod, @group, @stream, @lane, @track = Array.new(7) { SecureRandom.uuid_v7 }
    as_tenant do
      @system.define_taxonomy([ { level_id: @tribe, name: "Tribe" }, { level_id: @squad, name: "Squad" }, { level_id: @pod, name: "Pod" } ],
                              effective_on: @today)
    end
    @payments = create_unit("Payments", @tribe)
    @core = create_unit("Core", @tribe)
    @ledger = create_unit("Ledger", @squad, parent_id: @core)
    @till = create_unit("Till", @pod, parent_id: @ledger)
    as_tenant do
      @admin.declare_structure(@payments, levels: [ { level_id: @group, name: "Group", parent_level_ids: [], top: true },
                                                    { level_id: @stream, name: "Stream", parent_level_ids: [ @group ], top: false } ],
                                          conversion: {}, effective_on: @today + 1)
      @admin.move_unit(@ledger, @payments, effective_on: @today + 1, conversion: { @squad => @group, @pod => @stream })
    end
  end

  should "move a team out of a unit's own structure, converting it and the units beneath it in one change" do
    ada = as_tenant do
      person = create(:person, tenant: @tenant)
      OrgGraph::CommandHandler.new(actor: SYSTEM).tap do |people|
        people.record_person(person.id, provider: "espalia", effective_on: @today.iso8601, employment_status: "employed")
        people.set_membership(person.id, @till, provider: "espalia", effective_on: @today.iso8601, allocation: 1.0)
      end
      @system.add_unit_owner(@ledger, person.id, effective_on: @today)
      person
    end

    Rails.configuration.event_store.with_metadata(correlation_id: "request-1") { move_out }

    assert_equal [ nil, nil ], [ @ledger, @till ].map { structure.structure_in_force(it) }
    assert_equal [ @squad, @pod ], [ @ledger, @till ].map { structure.unit(it).level_id }
    assert_equal [ @core, @ledger ], [ @ledger, @till ].map { structure.unit(it).parent_id }
    assert_empty structure.misplaced_units

    moved = event_store.read.of_type(OrgGraph::Events::UnitMoved).backward.first
    assert_equal({ @group => @squad, @stream => @pod }, moved.data[:conversion])
    kinds = event_store.read.of_type(OrgGraph::Events::UnitKindChanged).backward.to_a.first(2)
    assert_equal [ "request-1" ] * 3, [ moved, *kinds ].map { it.metadata[:correlation_id] }

    as_tenant do
      assert_equal [ ada.id ], OrgUnit.find(@ledger).owners.map(&:id)
      assert_equal [ ada.id ], OrgMembership.where(unit_id: @till).pluck(:person_id)
      assert_equal [ @squad, @pod ], [ @ledger, @till ].map { OrgUnit.find(it).level_id }
      overview = OrgGraph::UnitsOverview.new
      assert_equal [ nil, nil ], [ @ledger, @till ].map { overview.structure_unit_of(overview.unit(it)) }

      levels = OrgFactPeriod.where(subject_id: @till, fact: "level", superseded_at: nil).order(:effective_from).map { it.value.values.first }
      assert_equal [ @pod, @stream, @pod ], levels
      parents = OrgFactPeriod.where(subject_id: @ledger, fact: "parent", superseded_at: nil).order(:effective_from).map { it.value.values.first }
      assert_equal [ @core, @payments, @core ], parents
      cause = OrgUnitActivity.find_by!(event_id: moved.event_id).cause_id
      assert_equal [ [ @ledger, "UnitKindChanged" ], [ @ledger, "UnitMoved" ], [ @till, "UnitKindChanged" ] ].sort,
                   OrgUnitActivity.where(cause_id: cause).map { [ it.unit_id, it.event_type ] }.sort
    end
  end

  should "move a team to the top of the organisation's structure" do
    move_out(parent_id: nil, conversion: { @group => @tribe, @stream => @squad })

    assert_equal [ nil, @ledger ], [ @ledger, @till ].map { structure.unit(it).parent_id }
    assert_equal [ @tribe, @squad ], [ @ledger, @till ].map { structure.unit(it).level_id }
    assert_nil structure.structure_in_force(@till)
  end

  should "move a team from one unit's own structure into another's" do
    lending = declare_lending

    move_out(parent_id: lending, conversion: { @group => @lane, @stream => @track })

    assert_equal [ lending, lending ], [ @ledger, @till ].map { structure.structure_in_force(it) }
    assert_equal [ @lane, @track ], [ @ledger, @till ].map { structure.unit(it).level_id }
    assert_empty structure.misplaced_units
    as_tenant do
      overview = OrgGraph::UnitsOverview.new
      assert_equal [ lending, lending ], [ @ledger, @till ].map { overview.structure_unit_of(overview.unit(it)) }
    end
  end

  should "refuse a conversion into a type the structure joined doesn't hold, or one that doesn't fit" do
    error = assert_raises(ArgumentError) { move_out(conversion: { @group => @squad, @stream => @stream }) }
    assert_equal "The conversion names a unit type the organisation's structure doesn't hold", error.message

    error = assert_raises(RuntimeError) { move_out(conversion: { @group => @pod, @stream => @squad }) }
    assert_equal "These units wouldn't fit the structure on #{@today + 2}: Till (Squad under Pod)", error.message
    assert_equal @payments, structure.structure_in_force(@ledger)
  end

  should "refuse a move out dated before a later tightening of the organisation's rules, naming the day" do
    as_tenant { @admin.set_kind_parents(@squad, parent_ids: [ @squad ], top: true, effective_on: @today + 3) }

    error = assert_raises(RuntimeError) { move_out(on: @today + 2) }
    assert_equal "These units wouldn't fit the structure on #{@today + 3}: Ledger (Squad under Tribe)", error.message
    assert_equal @payments, structure.structure_in_force(@ledger)
  end

  should "refuse a move out into a type that began after the move's date" do
    hub = SecureRandom.uuid_v7
    as_tenant { @admin.add_level(hub, "Hub", parent_ids: [ @squad ], top: false, effective_on: @today + 3) }

    error = assert_raises(RuntimeError) { move_out(on: @today + 2, conversion: { @group => @squad, @stream => hub }) }
    assert_equal "Hub begins on #{@today + 3}, so date this then or later", error.message

    move_out(on: @today + 3, conversion: { @group => @squad, @stream => hub })
    assert_equal hub, structure.unit(@till).level_id
  end

  should "date a move out no earlier than the last change to the structure it leaves" do
    trail = SecureRandom.uuid_v7
    as_tenant { @admin.add_level(trail, "Trail", parent_ids: [ @group ], top: false, effective_on: @today + 3, structure_unit_id: @payments) }

    error = assert_raises(RuntimeError) { move_out(on: @today + 2) }
    assert_equal "Payments's structure last changed on #{@today + 3}, so date the change then or later", error.message
  end

  should "refuse a change in the structure left dated before the move out" do
    cards = create_unit("Cards", @group, parent_id: @payments, on: @today + 1)
    move_out(on: @today + 2)

    error = assert_raises(RuntimeError) { create_unit("Wallet", @stream, parent_id: cards, on: @today + 1) }
    assert_equal "Payments's structure last changed on #{@today + 2}, so date the change then or later", error.message
  end

  should "carry a unit with a structure of its own out, nested in the structure it joins" do
    as_tenant do
      @admin.declare_structure(@till, levels: [ { level_id: @lane, name: "Lane", parent_level_ids: [], top: true } ],
                                      conversion: {}, effective_on: @today + 2)
    end
    tip = create_unit("Tip", @lane, parent_id: @till, on: @today + 2)

    move_out(on: @today + 2)

    assert_equal [ @squad, @pod, @lane ], [ @ledger, @till, tip ].map { structure.unit(it).level_id }
    assert_equal [ nil, nil, @till ], [ @ledger, @till, tip ].map { structure.structure_in_force(it) }
  end

  context "rights" do
    setup { @lending = declare_lending }

    should "need the right to change both structures, naming neither to a caller without one" do
      lane = create_unit("Lane A", @lane, parent_id: @lending, on: @today + 1)
      source_only = owner_of(@payments, lane)
      destination_only = owner_of(@ledger, @lending)
      [ [ source_only, lane ], [ destination_only, @lending ] ].each do |caller, parent_id|
        error = assert_raises(OrgGraph::Authorization::Refused) do
          move_out(as: caller, parent_id:, conversion: { @group => @lane, @stream => @track })
        end
        assert_equal "You need the right to change both structures to move a unit between them", error.message
      end
      assert_equal @payments, structure.structure_in_force(@ledger)

      move_out(as: owner_of(@payments, @lending), parent_id: @lending, conversion: { @group => @lane, @stream => @track })
      assert_equal @lending, structure.structure_in_force(@ledger)
    end

    should "need the right to change the organisation's structure for a move out" do
      error = assert_raises(OrgGraph::Authorization::Refused) { move_out(as: owner_of(@payments, @core)) }
      assert_equal "You need the right to change both structures to move a unit between them", error.message

      move_out(as: editor)
      assert_nil structure.structure_in_force(@ledger)
    end

    should "refuse the system" do
      error = assert_raises(OrgGraph::Authorization::Refused) { move_out(as: @system) }
      assert_equal "The system cannot move a unit between structures", error.message
    end
  end

  private

  def move_out(as: @admin, parent_id: @core, conversion: { @group => @squad, @stream => @pod }, on: @today + 2)
    as_tenant { as.move_unit(@ledger, parent_id, effective_on: on, conversion:) }
  end

  def declare_lending
    lending = create_unit("Lending", @tribe)
    as_tenant do
      @admin.declare_structure(lending, levels: [ { level_id: @lane, name: "Lane", parent_level_ids: [], top: true },
                                                  { level_id: @track, name: "Track", parent_level_ids: [ @lane ], top: false } ],
                                        conversion: {}, effective_on: @today + 1)
    end
    lending
  end

  # A member who owns each unit given, and nothing else.
  def owner_of(*unit_ids)
    as_tenant do
      person = create(:person, tenant: @tenant)
      OrgGraph::CommandHandler.new(actor: SYSTEM).record_person(person.id, provider: "espalia", effective_on: @today.iso8601,
                                                                           employment_status: "employed")
      unit_ids.each { @system.add_unit_owner(it, person.id, effective_on: @today) }
      tenant_user = create(:tenant_user, tenant: @tenant, role: :member, person:)
      OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: tenant_user.user, tenant_user:, person:))
    end
  end

  def editor
    as_tenant do
      tenant_user = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true)
      OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil))
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
