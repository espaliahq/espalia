# frozen_string_literal: true

require "test_helper"

# The unit drawer's writes (#124), one Operation per change, so MCP makes the
# same changes through the same commands.
class Operations::OrgGraph::UnitWritesTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @owner = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant, name: "Gil Ostrom"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .add_unit_owner(@org[:checkout], @owner.person.id, effective_on: "2026-01-05")
    end
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def unit(key) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[key]) }

  def membership(person, key)
    ActsAsTenant.with_tenant(@tenant) { OrgMembership.find_by(person_id: @org[person].id, unit_id: @org[key]) }
  end

  context "RenameUnit" do
    should "rename a unit from the day given, with the caller as actor" do
      result = call(Operations::OrgGraph::RenameUnit, unit_id: @org[:platform], name: " Core Platform ",
                                                      effective_on: "2026-11-01")

      assert_equal({ unit_id: @org[:platform], name: "Core Platform", effective_on: "2026-11-01" }, result)
      assert_equal "Core Platform", unit(:platform).name
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::UnitRenamed).last
      assert_equal @admin.person.id, event.data[:renamed_by_id]
    end

    should "default the effective date to today" do
      assert_equal Date.current.iso8601,
                   call(Operations::OrgGraph::RenameUnit, unit_id: @org[:platform], name: "Core")[:effective_on]
    end

    should "let an owner rename their unit and the units beneath it" do
      call(Operations::OrgGraph::RenameUnit, as: @owner, unit_id: @org[:payments], name: "Payments & Billing")

      assert_equal "Payments & Billing", unit(:payments).name
    end

    should "refuse someone else, saying who may" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        call(Operations::OrgGraph::RenameUnit, as: @owner, unit_id: @org[:platform], name: "Mine now")
      end

      assert_match(/Only a tenant admin, an Org Graph editor or an owner of Platform/, error.message)
      assert_equal "Platform", unit(:platform).name
    end

    should "refuse a unit the HRIS supplies, naming it" do
      error = assert_raises(RuntimeError) do
        call(Operations::OrgGraph::RenameUnit, unit_id: @org[:engineering], name: "Eng")
      end

      assert_match(/hibob/i, error.message)
      assert_equal "Engineering", unit(:engineering).name
    end

    should "refuse a malformed date or an unknown unit as bad parameters" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::RenameUnit, unit_id: @org[:platform], name: "Core", effective_on: "13/11/2026")
      end
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::RenameUnit, unit_id: SecureRandom.uuid_v7, name: "Core")
      end
    end
  end

  context "MoveUnit" do
    should "move a unit beneath another" do
      call(Operations::OrgGraph::MoveUnit, unit_id: @org[:payments], parent_id: @org[:platform])

      assert_equal @org[:platform], unit(:payments).parent_id
    end

    should "refuse an owner moving their unit somewhere they don't own" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        call(Operations::OrgGraph::MoveUnit, as: @owner, unit_id: @org[:payments], parent_id: @org[:platform])
      end

      assert_match(/can place a unit beneath Platform/, error.message)
      assert_equal @org[:checkout], unit(:payments).parent_id
    end
  end

  context "owners" do
    should "add and remove an owner" do
      call(Operations::OrgGraph::AddUnitOwner, unit_id: @org[:platform], person_id: @org[:ada].id)
      assert_includes unit(:platform).own_owners, @org[:ada]

      call(Operations::OrgGraph::RemoveUnitOwner, unit_id: @org[:platform], person_id: @org[:ada].id)
      assert_not_includes unit(:platform).own_owners, @org[:ada]
    end

    should "take owners on a unit the HRIS supplies" do
      call(Operations::OrgGraph::AddUnitOwner, unit_id: @org[:engineering], person_id: @org[:ada].id)

      assert_includes unit(:engineering).own_owners, @org[:ada]
    end

    should "refuse a member who owns nothing" do
      assert_raises(OrgGraph::Authorization::Refused) do
        call(Operations::OrgGraph::AddUnitOwner, as: @member, unit_id: @org[:platform], person_id: @member.person.id)
      end
    end

    should "refuse naming someone who has left" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::AddUnitOwner, unit_id: @org[:platform], person_id: @org[:faye].id)
      end
    end
  end

  context "members" do
    should "add a person with a role and allocation" do
      call(Operations::OrgGraph::AddMember, unit_id: @org[:platform], person_id: @org[:ezra].id,
                                            role: "Analyst", allocation: 0.4, effective_on: "2026-11-02")

      added = membership(:ezra, :platform)
      assert_equal [ "Analyst", 0.4, "espalia" ], [ added.role, added.allocation.to_f, added.provider ]
    end

    should "refuse someone already in the unit, keeping their terms" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::AddMember, unit_id: @org[:checkout], person_id: @org[:brook].id)
      end

      assert_equal "Brook Tamsin is already in Checkout", error.message
      assert_equal "Tech lead", membership(:brook, :checkout).role
    end

    should "refuse an allocation outside (0, 1]" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::AddMember, unit_id: @org[:platform], person_id: @org[:ezra].id, allocation: 1.5)
      end
    end

    should "move a member, keeping their terms" do
      call(Operations::OrgGraph::MoveMember, person_id: @org[:dot].id, from_unit_id: @org[:payments],
                                             unit_id: @org[:platform])

      assert_nil membership(:dot, :payments)
      assert_equal 1, membership(:dot, :platform).allocation
    end

    should "remove a member" do
      call(Operations::OrgGraph::RemoveMember, person_id: @org[:cyril].id, unit_id: @org[:checkout])

      assert_nil membership(:cyril, :checkout)
    end

    should "let an owner remove someone from their unit, and refuse them elsewhere" do
      call(Operations::OrgGraph::RemoveMember, as: @owner, person_id: @org[:cyril].id, unit_id: @org[:checkout])
      assert_nil membership(:cyril, :checkout)

      error = assert_raises(OrgGraph::Authorization::Refused) do
        call(Operations::OrgGraph::RemoveMember, as: @owner, person_id: @org[:ada].id, unit_id: @org[:platform])
      end
      assert_match(/Ada Quill's manager chain or an owner of Platform/, error.message)
    end

    should "place a hand-added person in a unit the HRIS supplies, but not someone the HRIS holds" do
      call(Operations::OrgGraph::AddMember, unit_id: @org[:engineering], person_id: @org[:ezra].id)
      assert_equal "espalia", membership(:ezra, :engineering).provider

      ActsAsTenant.with_tenant(@tenant) { @org[:cyril].update!(external_id: "hb-1", hris_source: "hibob") }
      error = assert_raises(RuntimeError) do
        call(Operations::OrgGraph::AddMember, unit_id: @org[:engineering], person_id: @org[:cyril].id)
      end
      assert_match(/hibob supplies this unit/, error.message)
    end
  end
end
