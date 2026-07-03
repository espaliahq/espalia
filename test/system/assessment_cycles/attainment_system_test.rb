# frozen_string_literal: true

require "application_system_test_case"

class AssessmentCycles::AttainmentSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: person, role: :admin)

      framework_id = SecureRandom.uuid_v7
      family = FactoryBot.create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      role = FactoryBot.create(:framework_role, name: "Engineer", role_family_id: family.role_family_id)
      (1..3).each do |ordinal|
        FactoryBot.create(:framework_level, role_id: role.role_id, ordinal: ordinal, code: "E#{ordinal}")
      end
      category = FactoryBot.create(:framework_capability_category,
        framework_id: framework_id, name: "Thinking")
      cap = FactoryBot.create(:framework_capability,
        category_id: category.category_id, name: "Strategic Thinking")
      FactoryBot.create(:framework_capability_role_binding,
        capability_id: cap.capability_id, role_id: role.role_id)

      @cycle = FactoryBot.create(:assessment_cycle, tenant: @tenant, name: "Q1 2026",
        framework_id: framework_id, status: "open")
      report = FactoryBot.create(:person, tenant: @tenant, name: "Report One")
      FactoryBot.create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
        person_id: report.id, role_id: role.role_id, level_ordinal: 2, status: "enrolled")
      FactoryBot.create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
        person_id: report.id, framework_id: framework_id,
        capability_stable_id: cap.stable_id, level_ordinal: 2,
        self_rated_frequency: "consistent")
    end

    sign_in_as(@user)
  end

  should "render the heatmap with attainment and coverage on desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit attainment_assessment_cycle_path(@cycle)

    assert_text "capability attainment"
    assert_text "Strategic Thinking"
    assert_text "100%"
    assert_text "1/1 assessed"
    assert_text "Thinking"
  end

  should "render the heatmap in a horizontally scrollable container on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit attainment_assessment_cycle_path(@cycle)

    assert_text "capability attainment"
    assert_text "Strategic Thinking"
    # The table scrolls inside its own container — the page body must not.
    body_overflows = page.evaluate_script(
      "document.body.scrollWidth > document.documentElement.clientWidth"
    )
    assert_not body_overflows, "page body must not scroll horizontally on mobile"
  end

  should "switch the perspective and column axis" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit attainment_assessment_cycle_path(@cycle)
    assert_text "Strategic Thinking"

    click_link "Manager"
    # No manager ratings exist → unassessed coverage under that perspective.
    assert_text "0/1 assessed"

    click_link "By role family"
    assert_text "Engineering"
  end

  should "reach the report from the cycle page" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit assessment_cycle_path(@cycle)

    assert_text "Capability attainment"
    click_link_with_js_fallback "Capability attainment →", expect_text: "Strategic Thinking"

    assert_text "1/1 assessed"
  end
end
