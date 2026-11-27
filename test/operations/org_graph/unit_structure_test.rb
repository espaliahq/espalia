# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::UnitStructureTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin)
      @owner = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      team = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: "2026-01-01")
      @payments, @billing = Array.new(2) { SecureRandom.uuid_v7 }
      structure.create_unit(@payments, "Payments", level_id: team, effective_on: "2026-01-01")
      structure.create_unit(@billing, "Billing", level_id: team, effective_on: "2026-01-01")
      structure.add_unit_owner(@payments, @owner.person.id, effective_on: "2026-01-01")
      @pod = SecureRandom.uuid_v7
      OrgGraph::StructureCommandHandler.new(actor: context(@admin)).declare_structure(
        @payments, levels: [ { level_id: @pod, name: "Pod", parent_level_ids: [ @pod ], top: true } ],
                   conversion: {}, effective_on: "2026-01-01"
      )
    end
  end

  def context(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def call(tenant_user, unit_id)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::OrgGraph::UnitStructure.call(context: context(tenant_user), params: { unit_id: })
    end
  end

  context "UnitStructure" do
    should "read a unit's own types for its owner, with what the panel needs to change them" do
      result = call(@owner, @payments)

      assert_equal [ @payments, "Payments", true ], result.values_at(:unit_id, :name, :declares)
      assert_equal [ [ "Pod", true, [ @pod ] ] ], result[:levels].map { it.values_at(:name, :top, :parent_ids) }
    end

    should "say a unit declares nothing when it has no structure of its own" do
      result = call(@admin, @billing)

      assert_equal [ false, [] ], result.values_at(:declares, :levels)
    end

    should "refuse an owner another unit's structure, and a member any" do
      assert_raises(Pundit::NotAuthorizedError) { call(@owner, @billing) }
      assert_raises(Pundit::NotAuthorizedError) { call(@member, @payments) }
    end

    should "refuse a unit the Org Graph doesn't hold" do
      error = assert_raises(Operations::Base::ParameterError) { call(@admin, SecureRandom.uuid_v7) }
      assert_includes error.message, "names no unit"
    end
  end
end
