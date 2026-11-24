# frozen_string_literal: true

require "test_helper"

# Setting an account's role through the operation the users screen and MCP share (#540).
class Operations::Tenants::SetAccountRoleTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant)
      @admin = create(:tenant_user, tenant: @tenant, person: @admin_person, role: :admin)
      @member = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant), role: :member)
    end
    @context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin_person)
  end

  def call(params, context: @context)
    ActsAsTenant.with_tenant(@tenant) { Operations::Tenants::SetAccountRole.call(context:, params:) }
  end

  should "make a member an admin, naming the admin who did" do
    assert_equal({ person_id: @member.person_id, role: "admin" }, call({ person_id: @member.person_id, role: "admin" }))

    assert_equal "admin", @member.reload.role
    set = Rails.configuration.event_store.read.of_type(AccountGrants::Events::AccountRoleSet).to_a.last
    assert_equal @admin_person.id, set.data[:set_by_id]
  end

  should "refuse to demote the last admin" do
    error = assert_raises(Operations::Base::ParameterError) { call({ person_id: @admin.person_id, role: "member" }) }

    assert_match "last tenant administrator", error.message
    assert_equal "admin", @admin.reload.role
  end

  should "refuse a role it doesn't know, and a person with no account" do
    assert_raises(Operations::Base::ParameterError) { call({ person_id: @member.person_id, role: "owner" }) }
    stranger = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
    assert_raises(Operations::Base::ParameterError) { call({ person_id: stranger.id, role: "admin" }) }
  end

  should "refuse a person with two accounts, rather than change either" do
    second = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, person: @member.person, role: :member) }

    error = assert_raises(Operations::Base::ParameterError) { call({ person_id: @member.person_id, role: "admin" }) }

    assert_match "more than one account", error.message
    assert_equal [ "member", "member" ], [ @member, second ].map { it.reload.role }
  end

  should "refuse a member" do
    context = AuthorizationContext.new(user: @member.user, tenant_user: @member, person: @member.person)

    assert_raises(Pundit::NotAuthorizedError) { call({ person_id: @member.person_id, role: "admin" }, context:) }
    assert_equal "member", @member.reload.role
  end
end
