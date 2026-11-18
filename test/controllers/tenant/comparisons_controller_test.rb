# frozen_string_literal: true

require "test_helper"

# Tenant admin → Comparisons: whether people can compare with their level,
# the smallest group, and how often the group scores are taken.
class Tenant::ComparisonsControllerTest < ActionDispatch::IntegrationTest
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

    should "show the settings and when the last and next snapshots are" do
      last = @tenant.today.beginning_of_month
      ActsAsTenant.with_tenant(@tenant) { LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: last) }

      get tenant_comparisons_path

      assert_response :success
      assert_select "input[type=checkbox][name='comparisons[enabled]'][checked]"
      assert_select "input[name='comparisons[min_group_size]'][value='5']"
      assert_select "select[name='comparisons[snapshot_every_months]'] option[selected][value='1']"
      assert_select "[data-last-snapshot]", text: last.strftime("%-d %b %Y")
      assert_select "[data-next-snapshot]", text: last.next_month.strftime("%-d %b %Y")
    end

    should "say the attainment report shows every group to someone who can open each assessment in it" do
      get tenant_comparisons_path

      assert_select "#comparisons_min_group_size_help", text: /attainment report hides smaller groups only from someone who can't open every assessment in them/
    end

    should "save the settings" do
      patch tenant_comparisons_path, params: { comparisons: { enabled: "0", min_group_size: "8", snapshot_every_months: "3" } }

      assert_redirected_to tenant_comparisons_path
      assert_equal "Comparisons are off. Saved.", flash[:notice]
      config = @tenant.reload.comparison_config
      assert_equal [ false, 8, 3 ], [ config.enabled, config.min_group_size, config.snapshot_every_months ]
    end

    should "keep the settings and say why for a group smaller than 4" do
      patch tenant_comparisons_path, params: { comparisons: { enabled: "1", min_group_size: "2", snapshot_every_months: "1" } }

      assert_response :unprocessable_content
      assert_includes response.body, "at least 4"
      assert_equal 5, @tenant.reload.comparison_config.min_group_size
    end

    should "show what was sent again, not the saved settings, so fixing one field doesn't undo the others" do
      patch tenant_comparisons_path, params: { comparisons: { enabled: "0", min_group_size: "2", snapshot_every_months: "3" } }

      assert_response :unprocessable_content
      assert_select "input[type=checkbox][name='comparisons[enabled]']:not([checked])"
      assert_select "input[name='comparisons[min_group_size]'][value='2']"
      assert_select "select[name='comparisons[snapshot_every_months]'] option[selected]", text: "3 months"
      assert_equal [ true, 5, 1 ], @tenant.reload.comparison_config.then { |c| [ c.enabled, c.min_group_size, c.snapshot_every_months ] }
    end
  end

  context "as a tenant admin sending a group size that isn't a whole number" do
    setup { sign_in @admin_user }

    should "refuse it rather than round it" do
      patch tenant_comparisons_path, params: { comparisons: { enabled: "1", min_group_size: "4.9", snapshot_every_months: "1" } }

      assert_response :unprocessable_content
      assert_equal 5, @tenant.reload.comparison_config.min_group_size
    end
  end

  context "as a member" do
    setup { sign_in @member_user }

    should "not see the settings" do
      get tenant_comparisons_path

      assert_redirected_to root_path
    end

    should "not change them" do
      patch tenant_comparisons_path, params: { comparisons: { enabled: "0" } }

      assert @tenant.reload.comparison_config.enabled
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
