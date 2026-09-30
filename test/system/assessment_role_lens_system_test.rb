# frozen_string_literal: true

require "application_system_test_case"

# Reading your own assessment through another level or role (ADR-22): the
# header chip is the lens control, the status pill gives way to the lens
# banner, and a rating made through the lens stays through a broadcast.
class AssessmentRoleLensSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = FactoryBot.create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee")
      @tenant_user = FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    context "at #{label} size" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@user)
      end

      should "read another level from the chip, then go back to the record" do
        visit assessment_path(@assignment)
        assert_selector "#assessment-status-pill"

        open_dropdown(scope: "##{Views::Assessments::LensControl::ID}")
        click_link_with_js_fallback("Engineer 3", expect_selector: "#assessment-lens-banner")

        within("#assessment-lens-banner") { assert_text "Software Engineer · E3" }
        assert_selector "h1", text: "Engineer 3"
        assert_no_selector "#assessment-status-pill"
        assert_current_path assessment_path(@assignment, as_level: 3)

        click_link_with_js_fallback("← Back to E2", expect_selector: "#assessment-status-pill")
        assert_no_selector "#assessment-lens-banner"
        assert_selector "h1", text: "Engineer 2"
      end

      should "read against another role and rate a capability it adds" do
        visit assessment_path(@assignment)
        assert_selector "#assessment-status-pill"
        assert_no_text "Roadmapping"

        open_dropdown(scope: "##{Views::Assessments::LensControl::ID}")
        click_button_with_js_fallback("Another role…", expect_selector: "##{Views::Assessments::LensRoleModal::ID}")
        select "Product Manager", from: "Role"
        # Both ladders have a level 2, so wait for the PM option itself — a
        # bare value check would pass with the picker never having run.
        assert_select "Level", selected: "PM2 · Product Manager 2"
        click_button_with_js_fallback("View", expect_selector: "#assessment-lens-banner")

        within("#assessment-lens-banner") { assert_text "Product Manager · PM2" }
        assert_selector "[data-scope-chip='outside-home']", text: "Not in your E2 role"
        within("#scoring-panel") { assert_text "Score unlocks at 1" }

        click_rating_frequency("#rating-#{@fx.pm_only.stable_id}-2", "Consistently")
        within("#scoring-panel") do
          assert_no_text "Score unlocks at"
          assert_text "Against PM2 you'd be"
        end
        assert_selector "#assessment-lens-banner"
      end

      should "land on the lens from a role in the framework explorer" do
        visit framework_path(@fx.framework_id)
        link = "a[data-my-ratings-link='#{@fx.pm.role_id}']"
        assert_selector link, visible: :all

        # Hover-revealed on desktop and inside the closed role pane on a phone;
        # the navigation is what's under test, so dispatch the click.
        page.execute_script("document.querySelector(arguments[0]).click()", link)

        assert_selector "#assessment-lens-banner", text: "Product Manager · PM2"
        assert_selector "[data-scope-chip='outside-home']", text: "Not in your E2 role"
      end
    end
  end

  context "a broadcast reload" do
    setup { sign_in_as(@user) }

    should "keep the page on the lens" do
      visit assessment_path(@assignment, as_role: @fx.pm.role_id, as_level: 2)
      assert_selector "#assessment-lens-banner"
      wait_for_stimulus "assessment-sync"
      assert_selector "#rating-#{@fx.pm_only.stable_id}-2", text: "Not rated"

      # A rating from elsewhere — another tab, the MCP server — broadcasts to
      # this page, which is not the rater, so the frames reload.
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::RateSelf.call(
          context: AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person),
          params: { assignment_id: @assignment.id, capability_stable_id: @fx.pm_only.stable_id,
                    level_ordinal: 2, frequency: "some", as_role_id: @fx.pm.role_id }
        )
      end

      assert_selector "#rating-#{@fx.pm_only.stable_id}-2", text: "Some of the time"
      assert_selector "[data-scope-chip='outside-home']"
      assert_selector "#assessment-lens-banner"
    end
  end
end
