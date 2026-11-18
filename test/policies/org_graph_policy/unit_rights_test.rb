# frozen_string_literal: true

require "test_helper"

class OrgGraphPolicy::UnitRightsTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin = as_tenant { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def rights_for(unit_id, viewer: @admin)
    as_tenant do
      context = AuthorizationContext.new(user: viewer.user, tenant_user: viewer, person: viewer.person)
      OrgGraphPolicy::UnitRights.new(OrgGraphPolicy.new(context, :org_graph), OrgUnit.find(unit_id), OrgGraph::UnitsOverview.new)
    end
  end

  def state_rules(level_id, parent_ids:, top:)
    as_tenant do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .set_kind_parents(level_id, parent_ids:, top:, effective_on: Date.current)
    end
  end

  should "offer a unit whose kind states no rules any unit above its level, and the top" do
    rights = rights_for(@org[:payments])

    assert_equal %w[Engineering Checkout Platform], rights.parent_choices.map(&:name)
    assert rights.root_choice?
  end

  should "offer only the kinds a unit's kind lists, and the top only when it may sit there" do
    state_rules(@org[:squad], parent_ids: [ @org[:team], @org[:squad] ], top: false)
    rights = rights_for(@org[:payments])

    assert_equal %w[Checkout Platform], rights.parent_choices.map(&:name)
    assert_not rights.root_choice?
    assert rights.move?
  end

  should "offer a unit of its own kind once the kind lists itself" do
    state_rules(@org[:team], parent_ids: [ @org[:department], @org[:team] ], top: false)

    assert_equal %w[Engineering Platform], rights_for(@org[:checkout]).parent_choices.map(&:name)
  end

  should "offer only the top to a unit whose kind may sit nowhere else" do
    guild, ledger = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.add_level(guild, "Guild", effective_on: Date.current)
      structure.create_unit(ledger, "Ledger", level_id: guild, effective_on: Date.current)
    end
    state_rules(guild, parent_ids: [], top: true)
    rights = rights_for(ledger)

    assert_empty rights.parent_choices
    assert rights.root_choice?
  end

  context "with a unit's own structure (#494)" do
    setup do
      group = SecureRandom.uuid_v7
      as_tenant do
        admin = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
        OrgGraph::StructureCommandHandler.new(actor: admin).declare_structure(
          @org[:checkout], levels: [ { level_id: group, name: "Group", parent_level_ids: [ group ], top: true } ],
                           conversion: { @org[:squad] => group }, effective_on: Date.current
        )
      end
    end

    should "offer a unit in the top structure the units inside it, as a move that converts" do
      assert_equal %w[Checkout Payments], rights_for(@org[:platform]).conversion_parent_choices.map(&:name)
      assert rights_for(@org[:platform]).move?
    end

    should "offer no such move out of it, nor to a unit that declares one itself" do
      assert_empty rights_for(@org[:payments]).conversion_parent_choices
      assert_empty rights_for(@org[:checkout]).conversion_parent_choices
    end
  end
end
