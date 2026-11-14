# frozen_string_literal: true

require "test_helper"

# The stale flags' read (#142), so MCP sees what the Units view flags.
class Operations::OrgGraph::StaleFactsTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
    end
  end

  def call(as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      Operations::OrgGraph::StaleFacts.call(context: context, params: params)
    end
  end

  should "return nothing within the threshold" do
    assert_equal({ stale: [] }, call(person_ids: [ @org[:cyril].id ]))
  end

  should "return a stale membership with ids only, and drop it once confirmed" do
    travel 91.days

    rows = call(person_ids: [ @org[:cyril].id ])[:stale]
    assert_includes rows, { person_id: @org[:cyril].id, fact: "membership", unit_id: @org[:checkout],
                            last_checked_on: 91.days.ago.to_date, checked_by_id: nil }

    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
      Operations::OrgGraph::ConfirmFact.call(context:, params: { person_id: @org[:cyril].id, fact: "membership",
                                                                 unit_id: @org[:checkout] })
    end
    assert_not(call(person_ids: [ @org[:cyril].id ])[:stale].any? { it[:unit_id] == @org[:checkout] })
  end

  should "look only at the people asked about" do
    travel 91.days

    assert_equal [ @org[:cyril].id ], call(person_ids: [ @org[:cyril].id ])[:stale].map { it[:person_id] }.uniq
  end

  should "refuse a member while the Org Graph is admins only" do
    assert_raises(Pundit::NotAuthorizedError) { call(as: @member, person_ids: [ @org[:cyril].id ]) }
  end
end
