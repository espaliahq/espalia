# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::UnitsTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin)
      @member = create(:tenant_user, tenant: @tenant, role: :member)
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true)
    end
  end

  def call(tenant_user: @admin)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::OrgGraph::Units.call(
        context: AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: nil), params: {}
      )
    end
  end

  should "list the live units in the page's tree order, with head counts, member ids and provider" do
    org = build_org_graph(@tenant)

    units = call[:units]

    assert_equal %w[Engineering Checkout Payments Platform], units.map { |u| u[:name] }
    engineering, checkout, payments, platform = units
    assert_equal [ 4, 3, 1, 2 ], units.map { |u| u[:headcount] }, "Brook, in two teams, counts once for Engineering"
    assert_equal [ "hibob", "espalia" ], [ engineering[:provider], platform[:provider] ]
    assert_equal({ level_id: org[:squad], parent_id: org[:checkout] }, payments.slice(:level_id, :parent_id))
    assert_equal [ org[:brook].id, org[:cyril].id ].sort, checkout[:member_ids].sort
    assert_empty engineering[:member_ids]
  end

  should "return the levels top first and the ids of active people in no unit, never names" do
    org = build_org_graph(@tenant)

    result = call

    assert_equal %w[Department Team Squad], result[:levels].map { |l| l[:name] }
    assert_includes result[:in_no_unit][:person_ids], org[:ezra].id
    assert_not_includes result[:in_no_unit][:person_ids], org[:faye].id
    assert_equal result[:in_no_unit][:person_ids].size, result[:in_no_unit][:count]
    assert_not_includes result.to_json, "Ada Quill"
  end

  should "leave out a retired unit" do
    org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .retire_unit(org[:payments], effective_on: "2026-02-01")
    end

    assert_not_includes call[:units].map { |u| u[:name] }, "Payments"
  end

  should "return empty lists for a tenant with no units" do
    assert_equal [], call[:units]
  end

  should "refuse a member, and an Org Graph editor who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member) }
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @editor) }
  end
end
