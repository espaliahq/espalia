# frozen_string_literal: true

require "application_system_test_case"

class AssessmentCycles::EvidenceReportSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person,
        tenant: @tenant, email: @user.email, name: "Admin")
      FactoryBot.create(:tenant_user,
        tenant: @tenant, user: @user, person: admin, role: :admin)

      framework_id = SecureRandom.uuid_v7
      FactoryBot.create(:framework_state,
        framework_id: framework_id, name: "Engineering Growth")
      role = FactoryBot.create(:framework_role, name: "Engineer")
      level = FactoryBot.create(:framework_level,
        role_id: role.role_id, ordinal: 2, title: "Mid Engineer", code: "E2")
      @cycle = FactoryBot.create(:assessment_cycle,
        tenant: @tenant, name: "Q1 2026", framework_id: framework_id)

      manager = FactoryBot.create(:person, tenant: @tenant, name: "Team Manager")
      report = FactoryBot.create(:person,
        tenant: @tenant, name: "Report One", manager: manager)
      author = FactoryBot.create(:person, tenant: @tenant, name: "Feedback Author")
      [ report, manager ].each do |participant|
        FactoryBot.create(:person_framework_assignment,
          tenant: @tenant, person_id: participant.id, framework_id: framework_id,
          role_id: role.role_id, level_id: level.level_id)
        FactoryBot.create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: participant.id,
          role_id: role.role_id, level_ordinal: 2, enrolled_at: 1.day.ago)
      end

      FactoryBot.create(:evidence_item, with_link: false,
        tenant: @tenant, author: manager, person_id: report.id,
        framework_id: framework_id, cycle_id: @cycle.cycle_id,
        source: "manager", feedback_direction: "manager_to_report")
      requested = FactoryBot.create(:evidence_item, with_link: false,
        tenant: @tenant, author: author, person_id: report.id,
        framework_id: framework_id, cycle_id: @cycle.cycle_id,
        source: "peer", feedback_direction: "peer_to_peer")
      FactoryBot.create(:evidence_item, with_link: false,
        tenant: @tenant, author: report, person_id: manager.id,
        framework_id: framework_id, cycle_id: @cycle.cycle_id,
        source: "peer", feedback_direction: "report_to_manager")
      FactoryBot.create(:evidence_item, with_link: false,
        tenant: @tenant, author: report, person_id: report.id,
        framework_id: framework_id, cycle_id: @cycle.cycle_id,
        source: "self", feedback_direction: "self")
      FactoryBot.create(:evidence_item, with_link: false,
        tenant: @tenant, author: author, person_id: report.id,
        framework_id: framework_id, cycle_id: @cycle.cycle_id,
        source: "peer", feedback_direction: nil)
      FactoryBot.create(:evidence_request,
        tenant: @tenant, requester: manager, requestee: author,
        person_id: report.id, framework_id: framework_id,
        cycle_id: @cycle.cycle_id, status: "responded",
        evidence_id: requested.id, requested_at: 1.minute.ago)
      FactoryBot.create(:evidence_request,
        tenant: @tenant, requester: manager, requestee: author,
        person_id: report.id, framework_id: framework_id,
        cycle_id: @cycle.cycle_id, status: "pending")
    end

    sign_in_as(@user)
  end

  should "render feedback and request coverage on desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit evidence_assessment_cycle_path(@cycle)

    assert_text "feedback & evidence"
    assert_text "Feedback provided"
    assert_text "Unsolicited"
    assert_text "Request fulfilment"
    assert_text "Feedback direction"
    assert_text "Manager → report"
    assert_text "Peer → peer"
    assert_text "Report → manager"
    assert_text "Peer → peer or report → manager (historical)"
    assert_text "Self-provided feedback"
    assert_text "Historical peer-source feedback cannot be split reliably"
    assert_text "Team Manager"
    screenshot("light_desktop")
  end

  should "render the report on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit evidence_assessment_cycle_path(@cycle)

    assert_text "Feedback provided"
    assert_text "Participant coverage"
    assert_text "Breakdown"
    assert_text "Feedback direction"
    assert_text "Peer → peer or report → manager (historical)"
    scroll_direction_card_into_view
    screenshot("light_mobile_direction")
  end

  should "render the report in dark mode on desktop and mobile" do
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-color-scheme", value: "dark" } ]
    )
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit evidence_assessment_cycle_path(@cycle)

    assert_text "Feedback provided"
    screenshot("dark_desktop")

    assert_text "Feedback direction"
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    assert_text "Participant coverage"
    scroll_direction_card_into_view
    screenshot("dark_mobile_direction")
  ensure
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
    )
  end

  should "reach feedback coverage from the cycle page" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit assessment_cycle_path(@cycle)
    assert_text "Feedback & evidence"

    click_link_with_js_fallback "Feedback & evidence →", expect_text: "Feedback provided"

    assert_text "Request fulfilment"
  end

  should "switch the grouped breakdown to role" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit evidence_assessment_cycle_path(@cycle)
    assert_text "Team Manager"

    click_link_with_js_fallback "By role", expect_text: "Engineer"

    assert_text "Feedback and evidence coverage by role"
  end

  private

  def scroll_direction_card_into_view
    heading = find("h2", text: "Feedback direction")
    page.execute_script(
      "arguments[0].scrollIntoView({ block: 'start' });", heading.native
    )
  end
end
