# frozen_string_literal: true

require "test_helper"

class OrgGraphPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    department, team, squad = Array.new(3) { SecureRandom.uuid_v7 }
    @engineering_id, @payments_id, @billing_id, @product_id = Array.new(4) { SecureRandom.uuid_v7 }

    as_tenant do
      @handler.define_taxonomy([ { level_id: department, name: "Department" }, { level_id: team, name: "Team" },
                                 { level_id: squad, name: "Squad" } ], effective_on: "2026-01-01")
      @handler.create_unit(@engineering_id, "Engineering", level_id: department, effective_on: "2026-01-01")
      @handler.create_unit(@payments_id, "Payments", level_id: team, parent_id: @engineering_id, effective_on: "2026-01-01")
      @handler.create_unit(@billing_id, "Billing", level_id: squad, parent_id: @payments_id, effective_on: "2026-01-01")
      @handler.create_unit(@product_id, "Product", level_id: department, effective_on: "2026-01-01")
      @lead = create(:person, tenant: @tenant)
      @report = create(:person, tenant: @tenant, manager: @lead)
      @other = create(:person, tenant: @tenant)
    end
  end

  context "with no tenant membership" do
    should "deny everything" do
      policy = policy_for(AuthorizationContext.new(user: create(:user), tenant_user: nil, person: @lead))

      assert_not policy.show?
      assert_not policy.edit_structure?
      assert_not policy.edit_unit?(unit(@engineering_id))
      assert_not policy.edit_membership?(@report, unit(@product_id))
    end
  end

  context "as a tenant member with no grant" do
    should "see the Org Graph and change nothing" do
      policy = policy_for(context_for(@other))

      assert policy.show?
      assert_not policy.edit_structure?
      assert_not policy.create_unit?(nil)
      assert_not policy.edit_unit?(unit(@engineering_id))
      assert_not policy.edit_membership?(@report, unit(@product_id))
    end
  end

  context "as a tenant admin" do
    should "change anything" do
      policy = policy_for(context_for(@other, role: :admin))

      assert_full_rights policy
    end
  end

  context "as an Org Graph editor" do
    should "change anything without being an admin" do
      policy = policy_for(context_for(@other, org_graph_editor: true))

      assert_full_rights policy
    end
  end

  context "as a unit owner" do
    setup do
      as_tenant { @handler.add_unit_owner(@payments_id, @other.id, effective_on: "2026-01-01") }
      @policy = policy_for(context_for(@other))
    end

    should "change the unit and every unit beneath it" do
      assert @policy.edit_unit?(unit(@payments_id))
      assert @policy.edit_unit?(unit(@billing_id))
      assert @policy.create_unit?(unit(@billing_id))
      assert @policy.edit_membership?(@report, unit(@billing_id))
    end

    should "keep the rights over a unit beneath that has owners of its own" do
      as_tenant { @handler.add_unit_owner(@billing_id, @lead.id, effective_on: "2026-02-01") }

      assert @policy.edit_unit?(unit(@billing_id))
    end

    should "not change the unit above, a unit elsewhere, or anything tenant-wide" do
      assert_not @policy.edit_unit?(unit(@engineering_id))
      assert_not @policy.edit_unit?(unit(@product_id))
      assert_not @policy.edit_structure?
      assert_not @policy.create_unit?(nil)
      assert_not @policy.edit_membership?(@report, unit(@product_id))
    end

    should "move a unit only to where they also hold rights" do
      assert @policy.move_unit?(unit(@billing_id), unit(@payments_id))
      assert_not @policy.move_unit?(unit(@billing_id), unit(@product_id))
      assert_not @policy.move_unit?(unit(@billing_id), nil)
    end

    should "record a succession only when they hold every unit it names" do
      assert @policy.record_succession?([ unit(@payments_id), unit(@billing_id) ])
      assert_not @policy.record_succession?([ unit(@billing_id), unit(@product_id) ])
    end

    should "move a member only between units they hold" do
      assert @policy.move_membership?(@other, unit(@payments_id), unit(@billing_id))
      assert_not @policy.move_membership?(@other, unit(@billing_id), unit(@product_id))
    end

    should "lose the rights once they leave" do
      as_tenant { @other.update!(status: "inactive") }

      assert_not policy_for(context_for(@other)).edit_unit?(unit(@billing_id))
    end
  end

  context "with a unit or person the Org Graph doesn't hold" do
    should "leave it to an admin or an editor" do
      owner = policy_for(context_for(@other))
      as_tenant { @handler.add_unit_owner(@engineering_id, @other.id, effective_on: "2026-01-01") }

      assert_not owner.edit_unit?(nil)
      assert_not owner.create_unit?(nil)
      assert_not policy_for(context_for(@lead)).edit_membership?(nil, nil)
      assert policy_for(context_for(@lead, org_graph_editor: true)).edit_membership?(nil, nil)
    end

    should "refuse an owner a person the graph doesn't hold, even in a unit they own" do
      as_tenant { @handler.add_unit_owner(@payments_id, @other.id, effective_on: "2026-01-01") }
      owner = policy_for(context_for(@other))

      assert_not owner.edit_membership?(nil, unit(@payments_id))
      assert_not owner.move_membership?(nil, unit(@payments_id), unit(@billing_id))
    end

    should "still let the manager chain end a membership of a unit that is gone" do
      assert policy_for(context_for(@lead)).edit_membership?(@report, nil)
    end
  end

  context "in a person's manager chain" do
    setup { @policy = policy_for(context_for(@lead)) }

    should "place their report in a unit they don't own, and move or end it" do
      assert @policy.edit_membership?(@report, unit(@product_id))
      assert @policy.move_membership?(@report, unit(@product_id), unit(@billing_id))
    end

    should "count a skip-level manager too" do
      grandreport = as_tenant { create(:person, tenant: @tenant, manager: @report) }

      assert @policy.edit_membership?(grandreport, unit(@product_id))
    end

    should "not change anyone else's memberships, or the unit itself" do
      assert_not @policy.edit_membership?(@other, unit(@product_id))
      assert_not @policy.edit_unit?(unit(@product_id))
      assert_not @policy.edit_structure?
    end

    should "lose the rights once they leave" do
      as_tenant { @lead.update!(status: "inactive") }

      assert_not policy_for(context_for(@lead)).edit_membership?(@report, unit(@product_id))
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def unit(id)
    as_tenant { OrgUnit.find(id) }
  end

  def context_for(person, role: :member, org_graph_editor: false)
    user = create(:user)
    tenant_user = as_tenant do
      create(:tenant_user, tenant: @tenant, user:, person:, role:, org_graph_editor:)
    end
    AuthorizationContext.new(user:, tenant_user:, person:)
  end

  def policy_for(context)
    OrgGraphPolicy.new(context, :org_graph)
  end

  def assert_full_rights(policy)
    assert policy.edit_structure?
    assert policy.create_unit?(nil)
    assert policy.edit_unit?(unit(@billing_id))
    assert policy.move_unit?(unit(@billing_id), nil)
    assert policy.record_succession?([ unit(@product_id), unit(@billing_id) ])
    assert policy.edit_membership?(@other, unit(@product_id))
    assert policy.move_membership?(@other, unit(@product_id), unit(@billing_id))
  end
end
