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

  def retire_payments
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: context(@admin)).withdraw_structure(@payments, conversion: {}, effective_on: Date.current)
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).retire_unit(@payments, effective_on: Date.current)
    end
  end

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

    should "name an unknown or retired unit to an admin" do
      error = assert_raises(Operations::Base::ParameterError) { call(@admin, SecureRandom.uuid_v7) }
      assert_includes error.message, "names no unit"

      retire_payments
      assert_equal "Payments is retired", assert_raises(Operations::Base::ParameterError) { call(@admin, @payments) }.message
    end

    should "give an owner the same refusal for a unit out of reach, an unknown one and their own once retired" do
      ActsAsTenant.with_tenant(@tenant) do
        structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        ledger = SecureRandom.uuid_v7
        structure.create_unit(ledger, "Ledger", level_id: OrgUnit.find(@billing).level_id, effective_on: "2026-01-01")
        structure.add_unit_owner(ledger, @owner.person.id, effective_on: "2026-01-01")
      end
      retire_payments
      refusals = [ @billing, SecureRandom.uuid_v7, @payments ].map do |unit_id|
        assert_raises(Pundit::NotAuthorizedError) { call(@owner, unit_id) }.message
      end
      assert_equal 1, refusals.uniq.size
    end
  end
end
