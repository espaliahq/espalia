# frozen_string_literal: true

require "test_helper"

class Tenant::TimeZonesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show the zone beside the date it makes today" do
      travel_to Time.utc(2026, 11, 16, 13, 30) do
        ActsAsTenant.with_tenant(@tenant) { @tenant.update!(time_zone: "Australia/Sydney") }

        get tenant_time_zone_path

        assert_response :success
        assert_select "select#tenant_time_zone option[selected][value='Australia/Sydney']"
        assert_includes response.body, "Tuesday 17 November 2026"
        assert_includes response.body, "rewrites nothing"
      end
    end

    should "save the zone and say what today now is" do
      travel_to Time.utc(2026, 11, 16, 13, 30) do
        patch tenant_time_zone_path, params: { tenant: { time_zone: "Australia/Sydney" } }

        assert_redirected_to tenant_time_zone_path
        assert_equal "Today is now Tuesday 17 November 2026 in Australia/Sydney.", flash[:notice]
        assert_equal "Australia/Sydney", @tenant.reload.time_zone
      end
    end

    should "keep the zone and say why for one it doesn't know" do
      patch tenant_time_zone_path, params: { tenant: { time_zone: "Middle Earth" } }

      assert_response :unprocessable_content
      assert_includes response.body, "isn&#39;t a time zone we know"
      assert_equal "UTC", @tenant.reload.time_zone
    end

    should "open on UTC to replace a stored zone no longer known" do
      @tenant.update_column(:time_zone, "Middle Earth")

      get tenant_time_zone_path

      assert_response :success
      assert_select "select#tenant_time_zone option[selected][value='UTC']"
      assert_select "select#tenant_time_zone option[value='Middle Earth']", count: 0
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "be refused the page and the change" do
      get tenant_time_zone_path
      assert_redirected_to root_path

      patch tenant_time_zone_path, params: { tenant: { time_zone: "Australia/Sydney" } }
      assert_redirected_to root_path
      assert_equal "UTC", @tenant.reload.time_zone
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
