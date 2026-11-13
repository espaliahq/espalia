# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::PersonGetTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin)
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true)
    end
  end

  def call(as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::OrgGraph::PersonGet.call(
        context: AuthorizationContext.new(user: as.user, tenant_user: as, person: nil), params:
      )
    end
  end

  should "return a person's teams, employment and history" do
    result = call(person_id: @org[:brook].id)

    assert_equal({ id: @org[:brook].id, name: "Brook Tamsin", status: "active", forgotten: false }, result[:person])
    checkout = result[:memberships].first
    assert_equal({ unit_id: @org[:checkout], unit_name: "Checkout", role: "Tech lead", allocation: 0.5,
                   provider: "espalia" }, checkout.except(:since))
    assert_equal [ "started" ], result[:employment].map { |fact| fact[:fact] }
    assert_includes result[:history].map { |change| change[:summary] }, "Joined Platform at 50%"
    assert result[:history].all? { |change| change[:learned_at].is_a?(String) && change.key?(:actor) }
  end

  should "read a forgotten person as a former member" do
    ActsAsTenant.with_tenant(@tenant) { @org[:brook].update_columns(name: nil, email: nil, forgotten_at: Time.current) }

    result = call(person_id: @org[:brook].id)

    assert_equal [ Person::FORMER_MEMBER, true ], result[:person].values_at(:name, :forgotten)
    assert_not_empty result[:history]
    assert_not_includes result.to_json, "Brook Tamsin"
  end

  should "refuse a person id that names no one" do
    assert_raises(Operations::Base::ParameterError) { call(person_id: SecureRandom.uuid_v7) }
  end

  should "refuse an Org Graph editor who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(as: @editor, person_id: @org[:brook].id) }
  end
end
