# frozen_string_literal: true

require "application_system_test_case"

class AssessmentCycles::CohortSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: person, role: :admin)

      framework_id = SecureRandom.uuid_v7
      role = FactoryBot.create(:framework_role, name: "Engineer")
      category = FactoryBot.create(:framework_capability_category, framework_id: framework_id)
      cap = FactoryBot.create(:framework_capability, category_id: category.category_id)
      FactoryBot.create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: role.role_id)

      @cycle = FactoryBot.create(:assessment_cycle, tenant: @tenant, name: "Q1 2026",
        framework_id: framework_id, status: "open")
      report = FactoryBot.create(:person, tenant: @tenant, name: "Report One")
      FactoryBot.create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
        person_id: report.id, role_id: role.role_id, level_ordinal: 2, status: "enrolled")
      FactoryBot.create(:assessment_cycle_progress, tenant: @tenant, cycle: @cycle,
        person_id: report.id, status: "started")
    end

    sign_in_as(@user)
  end

  should "render the funnel and participant list on desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit cohort_assessment_cycle_path(@cycle)

    assert_text "cohort progress"
    assert_text "Progress funnel"
    assert_text "Report One"
  end

  should "render the cohort view on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit cohort_assessment_cycle_path(@cycle)

    assert_text "Progress funnel"
    assert_text "Report One"
  end

  should "switch the breakdown pivot to role" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit cohort_assessment_cycle_path(@cycle)
    assert_text "Breakdown"

    click_link "By role"

    assert_text "Engineer"
  end
end
