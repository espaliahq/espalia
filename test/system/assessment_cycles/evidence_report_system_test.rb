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

      framework_id = @framework_id = SecureRandom.uuid_v7
      FactoryBot.create(:framework_state,
        framework_id: framework_id, name: "Engineering Growth")
      role = FactoryBot.create(:framework_role, name: "Engineer")
      level = FactoryBot.create(:framework_level,
        role_id: role.role_id, ordinal: 2, title: "Mid Engineer", code: "E2")
      @last_month = Time.current.beginning_of_month.prev_month
      @cycle = FactoryBot.create(:assessment_cycle,
        tenant: @tenant, name: "Q1 2026", framework_id: framework_id,
        opened_at: @last_month)

      @manager_user = FactoryBot.create(:user, password: "password123")
      manager = FactoryBot.create(:person, tenant: @tenant, name: "Team Manager", email: @manager_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: manager, role: :member)
      report = @report = FactoryBot.create(:person,
        tenant: @tenant, name: "Report One", manager: manager)
      author = @author = FactoryBot.create(:person, tenant: @tenant, name: "Feedback Author")
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
      FactoryBot.create(:evidence_item, with_link: false,
        tenant: @tenant, author: author, person_id: report.id,
        framework_id: framework_id, cycle_id: @cycle.cycle_id,
        source: "peer", feedback_direction: "peer_to_peer",
        recorded_at: @last_month + 2.days)
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
    assert_text "Proactive"
    assert_text "Request fulfilment"
    assert_text "Feedback direction"
    assert_text "Manager → report"
    assert_text "Peer → peer"
    assert_text "Report → manager"
    assert_text "Peer → peer or report → manager (historical)"
    assert_text "Self-provided feedback"
    assert_text "Historical peer-source feedback cannot be split reliably"
    assert_text "Team Manager"
    assert_no_text "Of which via"
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

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |name, size|
    should "show how much feedback came from another system on #{name}" do
      record_feedback_from("chip", 2)
      record_feedback_from("kudos", 1)
      record_feedback_from("github", 1)
      page.driver.browser.manage.window.resize_to(*size)
      visit evidence_assessment_cycle_path(@cycle)

      assert_text "Feedback provided"
      assert_selector "[data-origin-split] dt", text: "Of which via Chip"
      assert_selector "[data-origin-split] [data-origin='chip']", text: "2"
      assert_selector "[data-origin-split] dt", text: "Of which via Kudos"
      assert_selector "[data-origin-split] [data-origin='kudos']", text: "1"
      assert_no_selector "[data-origin-split] [data-origin='github']"
      assert_no_text "Of which via Espalia"
      screenshot("light_#{name}_origin_split")
    end
  end

  should "reach feedback coverage from the cycle page" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit assessment_cycle_path(@cycle)
    assert_text "Feedback & evidence"

    click_link_with_js_fallback "Feedback & evidence →", expect_text: "Feedback provided"

    assert_text "Request fulfilment"
  end

  should "narrow the report to one month of the cycle on desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit evidence_assessment_cycle_path(@cycle)
    assert_text "2 of 2 participants have feedback"

    select @last_month.strftime("%B %Y"), from: "Month"
    click_button_with_js_fallback "Apply",
      expect_text: "Feedback recorded and requests sent in #{@last_month.strftime("%B %Y")}"

    assert_text "1 of 2 participants have feedback"
    assert_equal @last_month.strftime("%Y-%m"), find_field("Month").value
    assert_csv_link_for(@last_month.strftime("%Y-%m"))
    screenshot("light_desktop_month")

    click_link_with_js_fallback "By role", expect_text: "Engineer"
    assert_text "Feedback recorded and requests sent in #{@last_month.strftime("%B %Y")}"
  end

  should "narrow the report to one month of the cycle on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit evidence_assessment_cycle_path(@cycle)
    assert_text "2 of 2 participants have feedback"

    select @last_month.strftime("%B %Y"), from: "Month"
    click_button_with_js_fallback "Apply",
      expect_text: "Feedback recorded and requests sent in #{@last_month.strftime("%B %Y")}"

    assert_text "1 of 2 participants have feedback"
    assert_csv_link_for(@last_month.strftime("%Y-%m"))
    screenshot("light_mobile_month")
  end

  should "offer an admin the whole cycle's CSV and not a manager" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit evidence_assessment_cycle_path(@cycle)
    assert_text "Feedback provided"
    assert_csv_link_for(nil)

    sign_out_and_in_as(@manager_user)
    visit evidence_assessment_cycle_path(@cycle)
    assert_text "Feedback provided"
    assert_no_link "Download CSV"
  end

  should "switch the grouped breakdown to role" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit evidence_assessment_cycle_path(@cycle)
    assert_text "Team Manager"

    click_link_with_js_fallback "By role", expect_text: "Engineer"

    assert_text "Feedback and evidence coverage by role"
  end

  private

  # Written straight to the column, as the importer's projection writes it.
  def record_feedback_from(system, count)
    ActsAsTenant.with_tenant(@tenant) do
      count.times do
        FactoryBot.create(:evidence_item, with_link: false,
          tenant: @tenant, author: @author, person_id: @report.id,
          framework_id: @framework_id, cycle_id: @cycle.cycle_id,
          source: "peer", feedback_direction: "peer_to_peer"
        ).update_columns(external_reference: { system: system })
      end
    end
  end

  def assert_csv_link_for(month)
    link = find_link("Download CSV", visible: true)
    query = Rack::Utils.parse_query(URI(link[:href]).query)
    assert_equal tenant_feedback_exports_path(format: :csv), URI(link[:href]).path
    assert_equal({ "cycle_id" => @cycle.cycle_id, "month" => month }.compact, query)
    assert_equal "false", link["data-turbo"]
  end

  def sign_out_and_in_as(user)
    Capybara.reset_sessions!
    sign_in_as(user)
  end

  def scroll_direction_card_into_view
    heading = find("h2", text: "Feedback direction")
    page.execute_script(
      "arguments[0].scrollIntoView({ block: 'start' });", heading.native
    )
  end
end
