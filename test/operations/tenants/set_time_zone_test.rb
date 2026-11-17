# frozen_string_literal: true

require "test_helper"

# The time zone that decides a tenant's today (#469).
class Operations::Tenants::SetTimeZoneTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :admin) }
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
  end

  def call(params, context: @context)
    ActsAsTenant.with_tenant(@tenant) { Operations::Tenants::SetTimeZone.call(context:, params:) }
  end

  should "set the zone and report the tenant's today in it" do
    travel_to Time.utc(2026, 11, 16, 13, 30) do
      result = call({ time_zone: "Australia/Sydney" })

      assert_equal({ time_zone: "Australia/Sydney", today: "2026-11-17" }, result)
      assert_equal "Australia/Sydney", @tenant.reload.time_zone
    end
  end

  should "move today from now on and rewrite no stored date" do
    leaver = ActsAsTenant.with_tenant(@tenant) { OrgLeaver.create!(person_id: SecureRandom.uuid, left_on: Date.new(2026, 11, 16)) }

    travel_to Time.utc(2026, 11, 16, 13, 30) do
      assert_equal Date.new(2026, 11, 16), @tenant.today
      call({ time_zone: "Australia/Sydney" })

      assert_equal Date.new(2026, 11, 17), @tenant.reload.today
      assert_equal Date.new(2026, 11, 16), leaver.reload.left_on
    end
  end

  should "set an IANA zone the settings page doesn't list" do
    call({ time_zone: "America/Toronto" })

    assert_equal "America/Toronto", @tenant.reload.time_zone
  end

  should "refuse a zone it doesn't know as bad input" do
    error = assert_raises(Operations::Base::ParameterError) { call({ time_zone: "Middle Earth" }) }

    assert_match(/isn't a time zone we know/, error.message)
    assert_equal "UTC", @tenant.reload.time_zone
  end

  should "refuse a member" do
    member = create(:user)
    member_tu = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: member, role: :member) }
    context = AuthorizationContext.new(user: member, tenant_user: member_tu, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { call({ time_zone: "Australia/Sydney" }, context:) }
    assert_equal "UTC", @tenant.reload.time_zone
  end
end
