# frozen_string_literal: true

require "test_helper"

class OrgGraph::StructureCrossingTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    admin_user = create(:user)
    admin = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: admin_user, role: :admin) }
    @admin = OrgGraph::StructureCommandHandler.new(actor: AuthorizationContext.new(user: admin_user, tenant_user: admin, person: nil))
  end

  def crosses?(key, parent_id)
    ActsAsTenant.with_tenant(@tenant) { OrgGraph::StructureCrossing.new(OrgUnit.find(@org[key]), parent_id).crosses? }
  end

  def declare(key, name)
    level_id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      @admin.declare_structure(@org[key], levels: [ { level_id:, name:, parent_level_ids: [ level_id ], top: true } ],
                                          conversion: { @org[:squad] => level_id }, effective_on: Date.current)
    end
  end

  should "not cross within the organisation's structure" do
    assert_not crosses?(:payments, @org[:platform])
    assert_not crosses?(:platform, nil)
  end

  should "cross into a parent that declares a structure, or sits beneath one" do
    declare(:checkout, "Group")

    assert crosses?(:platform, @org[:checkout])
    assert crosses?(:platform, @org[:payments])
  end

  should "cross out of a structure, to another parent or to the top" do
    declare(:checkout, "Group")

    assert crosses?(:payments, @org[:platform])
    assert crosses?(:payments, "")
    assert_not crosses?(:payments, @org[:checkout])
  end

  should "not count a unit's own structure as the one it leaves" do
    declare(:checkout, "Group")

    assert_not crosses?(:checkout, @org[:platform])
    assert_not crosses?(:checkout, nil)
  end

  should "leave a parent that isn't live to the move itself" do
    declare(:checkout, "Group")
    spare = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      @structure.create_unit(spare, "Spare", level_id: @org[:team], parent_id: @org[:engineering], effective_on: "2026-01-01")
      @structure.retire_unit(spare, effective_on: Date.current)
    end

    assert_not crosses?(:payments, spare)
    assert_not crosses?(:payments, SecureRandom.uuid_v7)
  end

  should "read the same number of queries however deep the tree" do
    shallow = count_queries { crosses?(:payments, @org[:platform]) }
    parent = @org[:payments]
    ActsAsTenant.with_tenant(@tenant) do
      @structure.set_kind_parents(@org[:squad], parent_ids: [ @org[:team], @org[:squad] ], top: false, effective_on: Date.current)
      8.times do |index|
        id = SecureRandom.uuid_v7
        @structure.create_unit(id, "Squad #{index}", level_id: @org[:squad], parent_id: parent, effective_on: Date.current)
        parent = id
      end
    end
    @org[:deepest] = parent

    assert_equal shallow, count_queries { crosses?(:deepest, @org[:platform]) }
  end

  private

  def count_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end
end
