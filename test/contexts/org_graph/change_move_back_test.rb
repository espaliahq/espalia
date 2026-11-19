# frozen_string_literal: true

require "test_helper"

class OrgGraph::ChangeMoveBackTest < ActiveSupport::TestCase
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
    @department, @team, @pod, @tribe, @squad = Array.new(5) { SecureRandom.uuid_v7 }
    as_tenant do
      @system.define_taxonomy([ { level_id: @department, name: "Department" }, { level_id: @team, name: "Team" }, { level_id: @pod, name: "Pod" } ],
                              effective_on: @today)
    end
    @engineering = create_unit("Engineering", @department)
    @payments = create_unit("Payments", @team, parent_id: @engineering)
    @payments_api = create_unit("Payments API", @pod, parent_id: @payments)
    @platform = create_unit("Platform", @team, parent_id: @engineering)
    as_tenant do
      @ada = create(:person, tenant: @tenant)
      people = OrgGraph::CommandHandler.new(actor: SYSTEM)
      people.record_person(@ada.id, provider: "espalia", effective_on: @today.iso8601, employment_status: "employed")
      people.set_membership(@ada.id, @payments_api, provider: "espalia", effective_on: @today.iso8601, allocation: 1.0)
      @system.add_unit_owner(@payments, @ada.id, effective_on: @today)
      @admin.declare_structure(@platform, levels: [ { level_id: @tribe, name: "Tribe", parent_level_ids: [], top: true },
                                                   { level_id: @squad, name: "Squad", parent_level_ids: [ @tribe ], top: false } ],
                                          conversion: {}, effective_on: @today + 1)
    end
    @started = placed
  end

  should "end where it started whether the move in is moved out again or changed back" do
    move_in
    assert_equal [ [ @platform, @tribe ], [ @payments, @squad ] ], [ @payments, @payments_api ].map { [ structure.unit(it).parent_id, structure.unit(it).level_id ] }

    as_tenant { @admin.move_unit(@payments, @engineering, effective_on: @today + 3, conversion: { @tribe => @team, @squad => @pod }) }
    assert_equal @started, placed
    assert_periods [ @team, @tribe, @team ], [ @engineering, @platform, @engineering ]

    move_in(on: @today + 4)
    as_tenant { change_back_group(cause_of_move(on: @today + 4)) }
    assert_equal @started, placed
    assert_periods [ @team, @tribe, @team ], [ @engineering, @platform, @engineering ]
    as_tenant do
      superseded = OrgFactPeriod.where(subject_id: @payments, effective_from: @today + 4).where.not(superseded_at: nil)
      assert_equal [ [ "level", @tribe ], [ "parent", @platform ] ], superseded.order(:fact).map { [ it.fact, it.value.values.first ] }
    end
  end

  should "change back a move in as one change, each unit taking back its own type" do
    move_in
    cause_id = as_tenant { cause_of_move }
    as_tenant { change_back_group(cause_id) }

    assert_equal @started, placed
    as_tenant do
      inverse = OrgUnitActivity.where(changes_back_id: OrgUnitActivity.caused_by(cause_id).select(:event_id))
      assert_equal 1, inverse.distinct.count(:cause_id)
      assert_equal [ [ @payments, "UnitKindChanged" ], [ @payments, "UnitMoved" ], [ @payments_api, "UnitKindChanged" ] ].sort,
                   inverse.map { [ it.unit_id, it.event_type ] }.sort
      assert OrgUnitActivity.caused_by(cause_id).all?(&:changed_back?)
      moved = event_store.read.of_type(OrgGraph::Events::UnitMoved).backward.first
      assert_equal({ @tribe => @team, @squad => @pod }, moved.data[:conversion])
      assert_equal (@today + 2).iso8601, moved.data[:effective_on].to_s
      assert_nil change_back_handler.group_refusal(Rails.configuration.event_store.read.event(moved.event_id).metadata[:correlation_id])
    end
  end

  should "change back a move out of a unit's own structure into it again" do
    move_in
    as_tenant { @admin.move_unit(@payments, @engineering, effective_on: @today + 3, conversion: { @tribe => @team, @squad => @pod }) }
    as_tenant { change_back_group(cause_of_move(on: @today + 3)) }

    assert_equal [ [ @platform, @tribe ], [ @payments, @squad ] ], [ @payments, @payments_api ].map { [ structure.unit(it).parent_id, structure.unit(it).level_id ] }
    assert_equal [ @platform, @platform ], [ @payments, @payments_api ].map { structure.structure_in_force(it) }
  end

  should "restore each unit's own type where the move made two types one" do
    core = create_unit("Core", @team, parent_id: @engineering)
    group = SecureRandom.uuid_v7
    as_tenant do
      @admin.declare_structure(core, levels: [ { level_id: group, name: "Group", parent_level_ids: [ group ], top: true } ],
                                     conversion: {}, effective_on: @today + 1)
      @admin.move_unit(@payments, core, effective_on: @today + 2, conversion: { @team => group, @pod => group })
    end
    as_tenant { change_back_group(cause_of_move) }

    assert_equal @started, placed
    assert_empty event_store.read.of_type(OrgGraph::Events::UnitMoved).backward.first.data[:conversion]
  end

  should "change back the change back of a move that made two types one" do
    core = create_unit("Core", @team, parent_id: @engineering)
    group = SecureRandom.uuid_v7
    as_tenant do
      @admin.declare_structure(core, levels: [ { level_id: group, name: "Group", parent_level_ids: [ group ], top: true } ],
                                     conversion: {}, effective_on: @today + 1)
      @admin.move_unit(@payments, core, effective_on: @today + 2, conversion: { @team => group, @pod => group })
    end
    moved_in = placed
    as_tenant { change_back_group(cause_of_move) }
    inverse = Rails.configuration.event_store.read.event(event_store.read.of_type(OrgGraph::Events::UnitMoved).backward.first.event_id)

    as_tenant do
      assert_nil change_back_handler.group_refusal(inverse.metadata[:correlation_id])
      change_back_group(inverse.metadata[:correlation_id])
    end

    assert_equal moved_in, placed
  end

  should "refuse to change back one part of the move alone, sending the caller to the whole change" do
    move_in
    as_tenant do
      OrgUnitActivity.caused_by(cause_of_move).each do |entry|
        assert_equal OrgGraph::ChangeBackHandler::WHOLE_MOVE, change_back_handler.refusal(entry)
        error = assert_raises(RuntimeError) { change_back_handler.change_back(entry) }
        assert_equal OrgGraph::ChangeBackHandler::WHOLE_MOVE, error.message
      end
    end
    assert_equal @platform, structure.unit(@payments).parent_id
  end

  should "refuse when a type change the move didn't make came in the same request" do
    data = create_unit("Data", @pod, parent_id: @engineering)
    as_tenant do
      event_store.with_metadata(correlation_id: "one-request") do
        @admin.move_unit(@payments, @platform, effective_on: @today + 2, conversion: { @team => @tribe, @pod => @squad })
        @admin.change_unit_kind(data, @team, effective_on: @today + 2)
      end
      assert_equal "This came with a move between structures, which can't be changed back yet", change_back_handler.group_refusal("one-request")
    end
    assert_equal @platform, structure.unit(@payments).parent_id
  end

  should "never retype a unit an HRIS supplies, by any route to one beneath the mover" do
    move_in
    as_tenant do
      assert_raises(RuntimeError) { @admin.hand_over_level(@squad, "hibob", field: "work.squad", matches: { @payments_api => "s-1" }, effective_on: @today + 3) }
      assert_raises(RuntimeError) { @system.create_unit(SecureRandom.uuid_v7, "Ledger", level_id: @squad, parent_id: @payments, provider: "hibob", external_ref: "l-1", effective_on: @today + 3) }
      event_store.publish(OrgGraph::Events::UnitHandedOver.new(data: { unit_id: @payments_api, provider: "hibob", previous_provider: "espalia",
                                                                      external_ref: "s-1", effective_on: (@today + 3).iso8601 },
                                                              metadata: { tenant_id: @tenant.id }), stream_name: EventStreamNaming.org_structure_stream)

      error = assert_raises(RuntimeError) { change_back_group(cause_of_move) }
      assert_match(/supplies Payments API; change it there\z/, error.message)
    end
    assert_equal @platform, structure.unit(@payments).parent_id
  end

  should "refuse when a unit has joined the moved team since" do
    move_in
    create_unit("Payouts", @squad, parent_id: @payments, on: @today + 3)

    error = assert_raises(RuntimeError) { as_tenant { change_back_group(cause_of_move) } }
    assert_equal "Payouts joined Payments's units since, so it has no type to go back to", error.message
    assert_equal @platform, structure.unit(@payments).parent_id
  end

  should "refuse when a unit has left the moved team since" do
    move_in
    cards = create_unit("Cards", @tribe, parent_id: @platform, on: @today + 3)
    as_tenant { @admin.move_unit(@payments_api, cards, effective_on: @today + 3) }

    error = assert_raises(RuntimeError) { as_tenant { change_back_group(cause_of_move) } }
    assert_equal "Payments API no longer sits beneath Payments", error.message
  end

  should "refuse when a later change to a unit that moved replaced it" do
    move_in
    as_tenant { @admin.move_unit(@payments, @engineering, effective_on: @today + 3, conversion: { @tribe => @team, @squad => @pod }) }

    error = assert_raises(RuntimeError) { as_tenant { change_back_group(cause_of_move) } }
    assert_equal "A later change has replaced this one; change that back first", error.message
  end

  should "refuse when the structure it left no longer holds a type to go back to" do
    move_in
    as_tenant { @admin.move_unit(@payments, @engineering, effective_on: @today + 3, conversion: { @tribe => @team, @squad => @pod }) }
    as_tenant { @admin.withdraw_structure(@platform, conversion: {}, effective_on: @today + 4) }

    error = assert_raises(RuntimeError) { as_tenant { change_back_group(cause_of_move(on: @today + 3)) } }
    assert_equal "A unit here would go back to a type the organisation's structure no longer holds", error.message
    assert_equal @started, placed
  end

  should "refuse a caller without the right to change both structures" do
    move_in
    as_tenant do
      cause_id = cause_of_move
      member = create(:tenant_user, tenant: @tenant, role: :member)
      context = AuthorizationContext.new(user: member.user, tenant_user: member, person: nil)
      assert_match(/\AOnly /, OrgGraph::ChangeBackHandler.new(actor: context).group_refusal(cause_id))
      assert_raises(OrgGraph::Authorization::Refused) { OrgGraph::ChangeBackHandler.new(actor: context).change_back_group(cause_id) }

      error = assert_raises(OrgGraph::Authorization::Refused) { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back_group(cause_id) }
      assert_equal "Only a tenant admin can move a unit between structures", error.message
    end
    assert_equal @platform, structure.unit(@payments).parent_id
  end

  private

  def move_in(on: @today + 2, conversion: { @team => @tribe, @pod => @squad })
    as_tenant { @admin.move_unit(@payments, @platform, effective_on: on, conversion:) }
  end

  def cause_of_move(on: @today + 2)
    OrgUnitActivity.where(unit_id: @payments, event_type: "UnitMoved", effective_on: on).order(:position).last.cause_id
  end

  def change_back_handler = OrgGraph::ChangeBackHandler.new(actor: @admin_context)

  def change_back_group(cause_id) = change_back_handler.change_back_group(cause_id)

  def placed
    as_tenant do
      units = [ @payments, @payments_api ].map { OrgUnit.find(it) }
      { units: units.map { [ it.id, it.parent_id, it.level_id ] }, owners: units.first.owners.map(&:id),
        members: OrgMembership.where(unit_id: @payments_api).pluck(:person_id),
        structures: [ @payments, @payments_api ].map { structure.structure_in_force(it) } }
    end
  end

  def assert_periods(levels, parents)
    as_tenant do
      assert_equal levels, current_periods(@payments, "level").map { it.value.values.first }
      assert_equal parents, current_periods(@payments, "parent").map { it.value.values.first }
    end
  end

  def current_periods(unit_id, fact)
    OrgFactPeriod.where(subject_id: unit_id, fact:, superseded_at: nil).order(:effective_from, :id).to_a
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
