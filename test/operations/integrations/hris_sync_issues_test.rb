# frozen_string_literal: true

require "test_helper"

class Operations::Integrations::HrisSyncIssuesTest < ActiveSupport::TestCase
  include OrgGraphFixture
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin)
      @member = create(:tenant_user, tenant: @tenant, role: :member)
      @org = build_org_graph(@tenant)
      HrisSyncIssue.create!(provider: "hibob", kind: "in_structure", unit_id: @org[:payments], parent_id: @org[:checkout],
                            structure_unit_id: @org[:engineering], first_seen_on: Date.new(2026, 11, 2), last_seen_on: Date.new(2026, 11, 9))
    end
  end

  def call(tenant_user: @admin)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Integrations::HrisSyncIssues.call(
        context: AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: nil), params: {}
      )
    end
  end

  should "name each issue's units by id and name, with the days a sync read it" do
    assert_equal [ { kind: "in_structure", provider: "hibob",
                     unit_id: @org[:payments], unit_name: "Payments",
                     parent_id: @org[:checkout], parent_name: "Checkout",
                     structure_unit_id: @org[:engineering], structure_unit_name: "Engineering",
                     first_seen_on: "2026-11-02", last_seen_on: "2026-11-09" } ], call[:issues]
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member) }
  end

  should "show nothing of another tenant's issues" do
    other = create(:tenant)
    admin = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin) }

    result = ActsAsTenant.with_tenant(other) do
      Operations::Integrations::HrisSyncIssues.call(
        context: AuthorizationContext.new(user: admin.user, tenant_user: admin, person: nil), params: {}
      )
    end

    assert_empty result[:issues]
  end
end
