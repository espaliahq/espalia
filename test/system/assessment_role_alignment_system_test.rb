# frozen_string_literal: true

require "application_system_test_case"

# Alignment against another role, end to end (ADR-22): the manager rates a
# cell only PM2 reads, starts alignment against PM2 from the lens banner, and
# only then does the assessee see that rating — through "Aligning · PM2" on
# their list — and agree it with them.
class AssessmentRoleAlignmentSystemTest < ApplicationSystemTestCase
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
    @pm_lens = assessment_path(@assignment, as_role: @fx.pm.role_id, as_level: 2)
    @pm_cell = "#rating-#{@fx.pm_only.stable_id}-2"

    # The shared cell both parties already agree on aligns when PM2 starts;
    # the PM-only cell carries the assessee's own view.
    rate(:rate_self, @fx.shared, "consistent")
    rate(:rate_as_manager, @fx.shared, "consistent")
    rate(:rate_self, @fx.pm_only, "some")
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    context "at #{label} size" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "keep the manager's PM2 rating private until alignment against PM2 starts" do
        sign_in_as(@manager_user)
        visit @pm_lens
        within("#assessment-lens-alignment") { assert_text "private until you start alignment against PM2" }
        click_rating_frequency(@pm_cell, "Consistently")

        switch_to(@user)
        visit @pm_lens
        assert_selector "#assessment-lens-banner"
        assert_no_selector "#secondaries-#{@fx.pm_only.stable_id}-2", text: "Manager"

        switch_to(@manager_user)
        visit @pm_lens
        click_selector_with_js_fallback("button[data-modal-target-id='start-lens-alignment-modal']",
                                        expect_selector: "#start-lens-alignment-modal")
        click_selector_with_js_fallback("#start-lens-alignment-modal button[type='submit']",
                                        expect_text: "Aligning with Alex against PM2")

        switch_to(@user)
        visit assessments_path
        click_link_with_js_fallback("Aligning · PM2", expect_selector: "#assessment-lens-banner")
        within("#assessment-lens-alignment") { assert_text "Your manager started alignment against PM2" }
        assert_selector "#secondaries-#{@fx.pm_only.stable_id}-2", text: "Manager"

        click_rating_frequency(@pm_cell, "Most of the time")
        assert_selector "#secondaries-#{@fx.pm_only.stable_id}-2", text: "Manager"
      end
    end
  end

  context "at desktop size" do
    should "let the manager complete PM2 alone, then show it aligned to the assessee" do
      rate(:rate_as_manager, @fx.pm_only, "consistent")
      start_pm_alignment
      align(@fx.pm_only, "occasional")

      sign_in_as(@manager_user)
      visit @pm_lens
      within("#alignment-completion-control") { assert_button "Mark alignment complete" }
      auto_confirm do
        click_button_with_js_fallback("Mark alignment complete", expect_text: "Alignment against PM2 complete")
      end
      within("#assessment-lens-alignment") { assert_text "Alignment against PM2 is complete" }

      switch_to(@user)
      visit assessment_path(@assignment)
      assert_selector "a[data-lens-alignment='PM2']", text: "Aligned · PM2"
      assert_selector "#assessment-status-pill", text: "In Progress"
    end

    should "freeze the cell E2 shares with PM2 on the E2 page, and say why" do
      start_pm_alignment

      sign_in_as(@user)
      visit assessment_path(@assignment)
      assert_selector "#rating-#{@fx.shared.stable_id}-2 span[title='Frozen — alignment against PM2 has started']"
      assert_selector "#rating-#{@fx.e_only.stable_id}-2 button"
    end
  end

  private

  def switch_to(user)
    Capybara.reset_session!
    sign_in_as(user)
  end

  def rate(command, capability, frequency)
    extra = command == :rate_as_manager ? { rated_by_id: @manager.id } : {}
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.public_send(
        command, @person.id, @fx.framework_id, capability.stable_id,
        level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id, **extra
      )
    end
  end

  def start_pm_alignment
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.start_alignment(
        @person.id, @fx.framework_id, @cycle_id, started_by_id: @manager.id, role_id: @fx.pm.role_id,
        level_ordinal: 2
      )
    end
  end

  def align(capability, frequency)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.align_assessment(
        @person.id, @fx.framework_id, capability.stable_id, level_ordinal: 2, aligned_frequency: frequency,
        cycle_id: @cycle_id, aligned_by_id: @manager.id, role_id: @fx.pm.role_id
      )
    end
  end
end
