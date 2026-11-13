# frozen_string_literal: true

require "test_helper"

# Retire, merge and split from the unit drawer (#138): each one change under
# one cause, with the caller as actor.
class Operations::OrgGraph::UnitSuccessionTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @owner = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant, name: "Gil Ostrom"))
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

  def unit(id) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(id) }

  def units_of(person) = ActsAsTenant.with_tenant(@tenant) { OrgMembership.where(person_id: @org[person].id).pluck(:unit_id) }

  def event_store = Rails.configuration.event_store

  # Every event sharing the cause of the last event of this type.
  def caused_with(type)
    cause = event_store.read.of_type(type).last.metadata[:correlation_id]
    event_store.read.to_a.select { |event| event.metadata[:correlation_id] == cause }.map { |event| event.class.name.demodulize }
  end

  # Faye has left, and her row in the unit stays until it retires.
  def with_leaver_in(key)
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .set_membership(@org[:faye].id, @org[key], **OrgGraphFixture::PROVENANCE)
    end
  end

  context "RetireUnit" do
    should "end every membership in the unit under the retirement's cause, naming the caller" do
      with_leaver_in(:payments)
      result = call(Operations::OrgGraph::RetireUnit, unit_id: @org[:payments], effective_on: "2026-11-02")

      assert_equal({ unit_id: @org[:payments], memberships_ended: 1, effective_on: "2026-11-02" }, result)
      assert unit(@org[:payments]).retired?
      assert_empty units_of(:dot)
      assert_equal @admin.person.id, event_store.read.of_type(OrgGraph::Events::UnitRetired).last.data[:retired_by_id]
      assert_includes caused_with(OrgGraph::Events::UnitRetired), "MembershipEnded"
    end

    should "refuse a unit with live sub-units, naming them" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::RetireUnit, unit_id: @org[:checkout])
      end

      assert_equal "Move or retire Checkout's sub-units first: Payments", error.message
      assert_not unit(@org[:checkout]).retired?
    end

    should "refuse a unit the HRIS supplies, naming it" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::RetireUnit, unit_id: @org[:engineering])
      end

      assert_equal "HiBob supplies Engineering; change it there", error.message
    end

    should "refuse someone who can't change the unit, saying who may" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        call(Operations::OrgGraph::RetireUnit, as: @owner, unit_id: @org[:platform])
      end

      assert_match(/owner of Platform/, error.message)
      assert_not unit(@org[:platform]).retired?
    end
  end

  context "MergeUnit" do
    should "move everyone into the unit that carries on and retire the other, under one cause" do
      result = call(Operations::OrgGraph::MergeUnit, unit_id: @org[:payments], into_unit_id: @org[:platform],
                                                     effective_on: "2026-11-02")

      assert_equal 1, result[:memberships_moved]
      assert unit(@org[:payments]).retired?
      assert_equal [ @org[:platform] ], units_of(:dot)
      caused = caused_with(OrgGraph::Events::UnitSucceeded)
      assert_includes caused, "UnitRetired"
      assert_includes caused, "MembershipMoved"
    end

    should "refuse merging a unit into itself, or one with live sub-units" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::MergeUnit, unit_id: @org[:platform], into_unit_id: @org[:platform])
      end
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::MergeUnit, unit_id: @org[:checkout], into_unit_id: @org[:platform])
      end
      assert_match(/sub-units first: Payments/, error.message)
    end

    should "refuse merging into a unit the HRIS supplies" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::MergeUnit, unit_id: @org[:payments], into_unit_id: @org[:engineering])
      end
      assert_equal "HiBob supplies Engineering; change it there", error.message
      assert_not ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[:payments]).retired? }
    end

    should "refuse an owner merging into a unit they can't change" do
      assert_raises(OrgGraph::Authorization::Refused) do
        call(Operations::OrgGraph::MergeUnit, as: @owner, unit_id: @org[:payments], into_unit_id: @org[:platform])
      end
      assert_not unit(@org[:payments]).retired?
    end
  end

  context "SplitUnit" do
    should "create the successors beside the unit, move the placed, and leave the rest in no team" do
      with_leaver_in(:platform)
      result = call(Operations::OrgGraph::SplitUnit, unit_id: @org[:platform], successor_names: [ " Core ", "Edge" ],
                                                     placements: { @org[:ada].id => "Core" }, effective_on: "2026-11-02")

      core, edge = result[:successors].map { |successor| unit(successor[:unit_id]) }
      assert_equal [ "Core", "Edge" ], [ core.name, edge.name ]
      assert_equal [ @org[:engineering], @org[:team] ], [ core.parent_id, core.level_id ]
      assert_equal [ 1, [ @org[:brook].id ] ], [ result[:placed], result[:unplaced] ]
      assert unit(@org[:platform]).retired?
      assert_equal [ core.id ], units_of(:ada)
      assert_equal [ @org[:checkout] ], units_of(:brook)

      caused = caused_with(OrgGraph::Events::UnitSucceeded)
      assert_equal 2, caused.count("UnitCreated")
      assert_includes caused, "MembershipMoved"
      assert_includes caused, "MembershipEnded"
    end

    should "refuse fewer than two successors, a repeated name, a stranger or an unknown successor" do
      [
        { successor_names: [ "Core" ] },
        { successor_names: [ "Core", " Core" ] },
        { successor_names: [ "Core", "Edge" ], placements: { @org[:cyril].id => "Core" } },
        { successor_names: [ "Core", "Edge" ], placements: { @org[:ada].id => "Rim" } }
      ].each do |params|
        assert_raises(Operations::Base::ParameterError, params.inspect) do
          call(Operations::OrgGraph::SplitUnit, unit_id: @org[:platform], **params)
        end
      end
      assert_not unit(@org[:platform]).retired?
      assert_equal 4, ActsAsTenant.with_tenant(@tenant) { OrgUnit.count }
    end
  end
end
