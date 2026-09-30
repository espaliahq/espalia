# frozen_string_literal: true

require "application_system_test_case"

# Declared explorations, end to end (ADR-22): the assessee declares the lens
# they are reading through, it appears on their list and as a chip on their
# manager's team card, the manager lands on the same lens from the chip and
# stops it with an outcome, and it leaves both lists. And when the manager
# shares one, Alex is notified and both feeds record it.
class AssessmentExplorationSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = FactoryBot.create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @user = FactoryBot.create(:user, password: "password123")
    @manager_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee",
                                           manager: @manager)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @pm_lens = assessment_path(@assignment, as_role: @fx.pm.role_id, as_level: 3)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    context "at #{label} size" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "declare from the lens banner, list it, and let the manager stop it from the team chip" do
        sign_in_as(@user)
        visit @pm_lens
        within("#assessment-lens-exploration") { assert_text "Nobody is told you're looking." }
        open_modal("start-exploration-modal")
        js_fill_in "#start-exploration-modal-note", with: "Curious about discovery work"
        click_selector_with_js_fallback("#start-exploration-modal button[type='submit']",
                                        expect_text: "You're exploring Product Manager · PM3")
        within("#assessment-lens-exploration") { assert_text "Exploring PM3 since" }
        assert_text "Curious about discovery work"

        visit assessments_path
        within("#explorations") { assert_text "0 of 2 rated · started by you" }

        switch_to(@manager_user)
        visit assessments_path
        assert_text "Team Assessments"
        click_selector_with_js_fallback("a[data-exploration='PM3']", expect_selector: "#assessment-lens-exploration")
        within("#assessment-lens-exploration") { assert_text "started by Alex" }

        open_modal("stop-exploration-modal")
        page.execute_script("document.getElementById('stop-exploration-modal-outcome-not_now').checked = true")
        click_selector_with_js_fallback("#stop-exploration-modal button[type='submit']",
                                        expect_text: "Stopped exploring Product Manager · PM3.")
        within("#assessment-lens-exploration") { assert_text "Alex isn't told you're looking." }

        visit assessments_path
        assert_text "Team Assessments"
        assert_no_selector "a[data-exploration='PM3']"

        switch_to(@user)
        visit assessments_path
        assert_text "My Assessments"
        assert_no_selector "#explorations"
      end

      should "tell Alex when the manager shares an exploration, and record it in both feeds" do
        sign_in_as(@manager_user)
        visit @pm_lens
        within("#assessment-lens-exploration") { assert_text "Alex isn't told you're looking." }
        open_modal("start-exploration-modal")
        click_selector_with_js_fallback("#start-exploration-modal button[type='submit']",
                                        expect_text: "Shared Product Manager · PM3 with Alex as an exploration.")
        within("#assessment-lens-exploration") { assert_text "started by you" }
        assert_selector "li[data-kind='exploration_started']", visible: :all
        perform_enqueued_jobs

        switch_to(@user)
        visit notifications_path
        assert_text "Morgan Manager shared an exploration of Product Manager · PM3 with you"
        visit @pm_lens
        within("#assessment-lens-exploration") { assert_text "started by Morgan" }
        assert_selector "li[data-kind='exploration_started']", visible: :all,
                        text: "Morgan Manager shared an exploration of Product Manager · PM3"
      end
    end
  end

  private

  def open_modal(id)
    click_selector_with_js_fallback("button[data-modal-target-id='#{id}']", expect_selector: "##{id}")
  end

  def switch_to(user)
    Capybara.reset_session!
    sign_in_as(user)
  end
end
