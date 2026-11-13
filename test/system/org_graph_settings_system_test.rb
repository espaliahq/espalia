# frozen_string_literal: true

require "application_system_test_case"

# The Org Graph settings screen (#126), a panel at a time, at both widths.
class OrgGraphSettingsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      @member = FactoryBot.create(:person, tenant: @tenant, name: "Mo Member")
      FactoryBot.create(:tenant_user, tenant: @tenant, person: @member, role: :member)
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "reach the settings from the Units view" do
        visit tenant_org_graph_path
        assert_text "Units and who is in each"
        click_link_with_js_fallback("Settings", expect_text: "Org Graph settings")
        assert_no_sideways_overflow
      end

      should "add an editor and remove them again" do
        visit tenant_org_graph_settings_path
        within("#org-graph-editors") { assert_text "None yet." }

        select "Mo Member", from: "Person to make an editor"
        click_button_with_js_fallback("Add an editor", expect_text: "Mo Member may now edit the Org Graph.")
        within("#org-graph-editors") { assert_selector "li", text: "Mo Member" }
        assert_no_sideways_overflow
        screenshot("editors_#{viewport}")

        click_button_with_js_fallback("remove-editor-#{@member.id}", expect_text: "Mo Member may no longer edit the Org Graph.")
        within("#org-graph-editors") { assert_text "None yet." }
      end

      should "count the stale facts and change when a fact goes stale" do
        ActsAsTenant.with_tenant(@tenant) do
          OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
            .record_person(@member.id, provider: "espalia", effective_on: Date.current, employment_status: "employed",
                                       title: "Engineer")
          OrgFactAge.where(person_id: @member.id).update_all(checked_at: 45.days.ago)
        end

        visit tenant_org_graph_settings_path
        within("#org-graph-freshness") { assert_text "No fact is stale." }

        select "30 days", from: "Stale after"
        click_button_with_js_fallback("org-graph-freshness-save", expect_text: "A fact now counts as stale after 30 days.")
        within("#org-graph-freshness") do
          assert_text "1 fact is stale:"
          assert_text "Title: 1"
          assert_select "Stale after", selected: "30 days"
        end
        assert_no_sideways_overflow
        screenshot("freshness_#{viewport}")
      end
    end
  end
end
