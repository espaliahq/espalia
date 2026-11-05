# frozen_string_literal: true

require "application_system_test_case"

# Reading a past cycle from the header's cycle switcher: the page reloads that
# cycle read-only, with a banner in place of the status pill, and leads back
# to the open cycle (https://github.com/mr-yum/growth-os/issues/669).
class AssessmentPastCycleSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = FactoryBot.create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, past_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(@person.id, @fx.framework_id, @fx.shared.stable_id,
        level_ordinal: 2, frequency: "occasional", cycle_id: past_id)
    end
    close_and_open_next_role_lens_cycle(@person, @fx, past_id, tenant: @tenant)
    # Each cycle's card opens at its own home level: E2 then, E3 now.
    @past_pill = "#rating-#{@fx.shared.stable_id}-2"
    @open_pill = "#rating-#{@fx.shared.stable_id}-3"
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    context "at #{label} size" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@user)
      end

      should "open a past cycle read-only from the switcher, then go back" do
        visit assessment_path(@assignment)
        assert_selector "#assessment-status-pill"
        assert_selector "#{@open_pill} [data-dropdown-target='trigger']"

        open_dropdown(scope: "##{Views::Assessments::CycleControl::ID}")
        click_link_with_js_fallback("Q3 2026", expect_selector: "##{Views::Assessments::PastCycleBanner::ID}")

        within("##{Views::Assessments::PastCycleBanner::ID}") do
          assert_text "Q3 2026 closed on"
          assert_text "Read-only"
        end
        assert_no_selector "#assessment-status-pill"
        assert_selector "h1", text: "Engineer 2"
        assert_selector @past_pill, text: "Most of the time"
        assert_no_selector "#{@past_pill} [data-dropdown-target='trigger']"

        click_link_with_js_fallback("← Back to the open cycle", expect_selector: "#assessment-status-pill")
        assert_no_selector "##{Views::Assessments::PastCycleBanner::ID}"
        assert_selector "h1", text: "Engineer 3"
      end
    end
  end
end
