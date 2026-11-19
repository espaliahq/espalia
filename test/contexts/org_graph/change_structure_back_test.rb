# frozen_string_literal: true

require "test_helper"

# Changing back a unit's own structure: its declaration or its withdrawal,
# with every unit it retyped, as one change
# ([#494](https://github.com/espaliahq/espalia/issues/494)).
class OrgGraph::ChangeStructureBackTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @admin_context = as_tenant do
      tenant_user = create(:tenant_user, tenant: @tenant, role: :admin)
      AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil)
    end
    @admin = OrgGraph::StructureCommandHandler.new(actor: @admin_context)
    @today = Date.new(2026, 11, 1)
    @tribe, @squad, @pod, @group, @stream = Array.new(5) { SecureRandom.uuid_v7 }
    as_tenant do
      @system.define_taxonomy([ { level_id: @tribe, name: "Tribe" }, { level_id: @squad, name: "Squad" }, { level_id: @pod, name: "Pod" } ],
                              effective_on: @today)
    end
    @payments = create_unit("Payments", @tribe)
    @checkout = create_unit("Checkout", @squad, parent_id: @payments)
    @basket = create_unit("Basket", @pod, parent_id: @checkout)
  end

  should "withdraw a declaration, sending each unit back to its own type though two types became one" do
    declare(levels: [ { level_id: @group, name: "Group", parent_level_ids: [ @group ], top: true } ],
            conversion: { @squad => @group, @pod => @group })
    cause_id = structure_cause

    change_back_group(cause_id)

    assert_empty structure.declared_structures
    assert_equal [ @squad, @pod ], [ @checkout, @basket ].map { structure.unit(it).level_id }
    parts = as_tenant { OrgUnitActivity.caused_by(cause_id).to_a }
    assert_equal 3, parts.size
    assert parts.all?(&:changed_back?)
    assert_equal 1, as_tenant { OrgUnitActivity.where(changes_back_id: parts.map(&:event_id)).distinct.count(:cause_id) }
  end

  should "declare a withdrawn structure again with the same type ids, each unit back at its type in it" do
    declare
    as_tenant { @admin.withdraw_structure(@payments, conversion: { @group => @squad, @stream => @pod }, effective_on: @today) }

    change_back_group(structure_cause)

    assert_equal [ @group, @stream ], structure.declared_structures.fetch(@payments).kinds.map(&:id)
    assert_equal [ @group, @stream ], [ @checkout, @basket ].map { structure.unit(it).level_id }
    assert_empty structure.misplaced_units
    assert_equal [ "Group", "Stream" ], latest_structure_entry.after["types"]
    assert_equal "Group", as_tenant { OrgFactPeriod.current.where(subject_id: @group, fact: "kind").pick(Arel.sql("value ->> 'name'")) }
  end

  should "change back only the whole change, never its structure or one of its units alone" do
    declare
    as_tenant do
      change_back = OrgGraph::ChangeBackHandler.new(actor: @admin_context)
      OrgUnitActivity.caused_by(structure_cause).each do |entry|
        assert_equal "This came with a change to a unit's own structure, so change the whole change back", change_back.refusal(entry)
      end
    end
  end

  should "refuse, once it writes, while a unit has joined the structure since, as it has no type to go back to" do
    declare
    cause_id = structure_cause
    create_unit("Till", @stream, parent_id: @checkout)

    error = assert_raises(RuntimeError) { change_back_group(cause_id) }
    assert_equal "Till joined Payments's units since, so it has no type to go back to", error.message
    assert_includes structure.declared_structures.keys, @payments
  end

  should "refuse a change to a structure's types, and a declaration a later change to them overtook" do
    declare
    declaration = structure_cause
    as_tenant { @admin.add_level(SecureRandom.uuid_v7, "Lane", structure_unit_id: @payments, effective_on: @today) }

    assert_equal "A change to a structure's unit types can't be changed back yet", group_refusal(structure_cause)
    assert_equal "A change to a structure's unit types can't be changed back yet",
                 as_tenant { OrgGraph::ChangeBackHandler.new(actor: @admin_context).refusal(latest_structure_entry) }
    assert_equal "A later change has replaced this one; change that back first", group_refusal(declaration)
  end

  private

  def groups_and_streams
    [ { level_id: @group, name: "Group", parent_level_ids: [], top: true },
      { level_id: @stream, name: "Stream", parent_level_ids: [ @group ], top: false } ]
  end

  def declare(levels: groups_and_streams, conversion: { @squad => @group, @pod => @stream })
    as_tenant { @admin.declare_structure(@payments, levels:, conversion:, effective_on: @today) }
  end

  def latest_structure_entry = as_tenant { OrgUnitActivity.where(subject: "structure").order(:position).last }

  def structure_cause = latest_structure_entry.cause_id

  def change_back_group(cause_id)
    as_tenant { OrgGraph::ChangeBackHandler.new(actor: @admin_context).change_back_group(cause_id) }
  end

  def group_refusal(cause_id)
    as_tenant { OrgGraph::ChangeBackHandler.new(actor: @admin_context).group_refusal(cause_id) }
  end

  def structure = as_tenant { OrgGraph::Repository.new.load_structure }

  def create_unit(name, level_id, parent_id: nil)
    unit_id = SecureRandom.uuid_v7
    as_tenant { (parent_id ? @admin : @system).create_unit(unit_id, name, level_id:, parent_id:, effective_on: @today) }
    unit_id
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
