# frozen_string_literal: true

require "test_helper"

class Tenant::PlanningInputsHistoriesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                                   person: create(:person, tenant: @tenant, name: "Ada Admin"))
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member, org_graph_editor: true, team_planner: true)
      role = create(:framework_role, tenant: @tenant)
      @level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
      @band = add_pay_band!(level: @level, location: "Fixtureland", currency: "AUD", period: "year",
                            minimum: 100_000, midpoint: 120_000, maximum: 140_000, changed_by_id: admin.person_id)
      @band.midpoint = 125_000
      save_planning_input!(:pay_bands, @band, changed_by_id: admin.person_id)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "list each band change newest first, with its figures before and after" do
      get tenant_planning_inputs_history_path("pay_bands")

      assert_response :success
      assert_select "h1", text: "Pay band history"
      assert_select "#planning-inputs-history li", count: 2
      assert_select "#planning-inputs-history li[data-history-change='changed']:first-child" do
        assert_select "p", text: /Before: AUD 100,000 to 140,000 a year · Midpoint 120,000/
        assert_select "p", text: /After: AUD 100,000 to 140,000 a year · Midpoint 125,000/
        assert_select "p", text: /\ABy Ada Admin on /
      end
    end

    should "give each change's time in the tenant's own time zone" do
      @tenant.update!(time_zone: "Australia/Sydney")
      travel_to Time.utc(2026, 12, 1, 22, 0) do
        ActsAsTenant.with_tenant(@tenant) do
          @band.midpoint = 130_000
          save_planning_input!(:pay_bands, @band)
        end
      end

      get tenant_planning_inputs_history_path("pay_bands")

      assert_select "#planning-inputs-history li:first-child p", text: "On 2 Dec 2026, 09:00"
    end

    should "show a change that left the figures alone once, as unchanged" do
      ActsAsTenant.with_tenant(@tenant) do
        @band.position = 2
        save_planning_input!(:pay_bands, @band)
      end

      get tenant_planning_inputs_history_path("pay_bands")

      assert_select "#planning-inputs-history li:first-child" do
        assert_select "p", text: "Unchanged: AUD 100,000 to 140,000 a year · Midpoint 125,000"
        assert_select "p", text: /Before|After/, count: 0
      end
    end

    should "say so when an input has no changes yet" do
      get tenant_planning_inputs_history_path("budget_lines")

      assert_response :success
      assert_select "h1", text: "Budget history"
      assert_includes response.body, "No changes yet"
    end

    should "link each screen to its history" do
      get tenant_pay_bands_path
      assert_select "a[href='#{tenant_planning_inputs_history_path('pay_bands')}']", text: "Band history"
      assert_select "a[href='#{tenant_planning_inputs_history_path('exchange_rates')}']", text: "Rate history"

      get tenant_budget_lines_path
      assert_select "a[href='#{tenant_planning_inputs_history_path('budget_lines')}']", text: "History"
    end
  end

  context "as a member, even a planner and an Org Graph editor" do
    setup { sign_in @member_user }

    should "refuse every history" do
      %w[pay_bands exchange_rates budget_lines].each do |inputs|
        get tenant_planning_inputs_history_path(inputs)

        assert_redirected_to root_path
        assert_equal "You are not authorized to perform this action.", flash[:alert]
      end
    end
  end
end
