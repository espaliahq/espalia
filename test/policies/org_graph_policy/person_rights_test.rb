# frozen_string_literal: true

require "test_helper"

class OrgGraphPolicy::PersonRightsTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def rights_for(person, viewer:, role: :member)
    as_tenant do
      tenant_user = create(:tenant_user, tenant: @tenant, person: viewer, role:)
      policy = OrgGraphPolicy.new(AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: viewer), :org_graph)
      memberships = OrgGraph::PersonProfile.new(person.reload).memberships
      [ OrgGraphPolicy::PersonRights.new(policy, person, OrgGraph::UnitsOverview.new, memberships), memberships.index_by(&:unit_id) ]
    end
  end

  def names(units) = units.map(&:name)

  context "as a tenant admin" do
    setup { @viewer = as_tenant { create(:person, tenant: @tenant) } }

    should "change a hand-added membership, to any unit the person isn't in" do
      rights, held = rights_for(@org[:brook], viewer: @viewer, role: :admin)

      assert rights.membership?(held[@org[:checkout]])
      assert_equal %w[Engineering Payments], names(rights.destinations(held[@org[:checkout]]))
      assert_equal %w[Engineering Payments], names(rights.join_choices)
    end

    should "leave a membership an HRIS supplies to the HRIS" do
      as_tenant do
        @org[:ada].update_columns(hris_source: "hibob", external_id: "hb-ada")
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .set_membership(@org[:ada].id, @org[:engineering], provider: "hibob", effective_on: "2026-01-05")
      end
      rights, held = rights_for(@org[:ada], viewer: @viewer, role: :admin)

      assert_not rights.membership?(held[@org[:engineering]])
      assert_empty rights.destinations(held[@org[:engineering]])
      assert rights.membership?(held[@org[:platform]])
    end

    should "not add someone who has left to a team" do
      rights, = rights_for(@org[:faye], viewer: @viewer, role: :admin)

      assert_not rights.join?
    end

    should "change nothing for a forgotten person" do
      as_tenant { @org[:brook].update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }
      rights, held = rights_for(@org[:brook], viewer: @viewer, role: :admin)

      assert_not rights.membership?(held[@org[:checkout]])
      assert_not rights.join?
    end
  end

  context "as the owner of a unit" do
    setup do
      as_tenant do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .add_unit_owner(@org[:checkout], @org[:cyril].id, effective_on: "2026-01-01")
      end
    end

    should "change memberships of that unit and the units beneath it, and no others" do
      rights, held = rights_for(@org[:brook], viewer: @org[:cyril])

      assert rights.membership?(held[@org[:checkout]])
      assert_not rights.membership?(held[@org[:platform]])
      assert_equal %w[Payments], names(rights.destinations(held[@org[:checkout]]))
      assert_equal %w[Payments], names(rights.join_choices)
    end
  end

  context "as a tenant member with no grant" do
    should "change nothing" do
      rights, held = rights_for(@org[:brook], viewer: @org[:ezra])

      assert_not rights.membership?(held[@org[:checkout]])
      assert_not rights.join?
    end
  end
end
