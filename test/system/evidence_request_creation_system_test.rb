# frozen_string_literal: true

require "application_system_test_case"

# G1 — the per-cell "Request evidence" flow on the assessment screen: open the
# modal from a capability card, add a recipient via a suggestion chip, send, and
# see the request land on the evidence hub.
class EvidenceRequestCreationSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @manager_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager Jane")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @report = FactoryBot.create(:person, tenant: @tenant, name: "Report Alex", manager: @manager)
      # A peer of the assessee (same manager) → appears as a suggestion.
      @peer = FactoryBot.create(:person, tenant: @tenant, name: "Pat Peer", manager: @manager)

      handler = Frameworks::CommandHandler.new
      pd = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Career Framework")
      rf = SecureRandom.uuid_v7
      role = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf, "Eng")
      handler.add_role(@framework_id, role, rf, "Software Engineer", "E", "ic")
      l2 = SecureRandom.uuid_v7
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, l2, role, 2, "Senior", "E2")
      cat = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat, "Thinking", ordinal: 1)
      @cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap_id, @cap_stable, cat, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, role, weight: 1.0)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 2,
        "Synthesises information from multiple sources")
      handler.publish_version(@framework_id, "test")

      pd.assign_to_framework(@report.id, @framework_id, role, FrameworkState::Level.find_by!(level_id: l2).level_id)
      cycle = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle.define_cycle(@cycle_id, @framework_id, "Q1 2026 Review", "regular", 1, defined_by: @manager.id)
      cycle.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)
      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
      pd.rate_self(@report.id, @framework_id, @cap_stable, level_ordinal: 2,
        frequency: "occasional", cycle_id: @cycle_id, comment: "x")
    end

    sign_in_as(@manager_user)
  end

  def open_request_modal
    visit assessment_path(@report_assignment)
    assert_text "Critical Thinking"
    # Open the evidence-actions kebab, then the "Request evidence" item.
    # JS-dispatch so a starved CI loop can't drop the Stimulus clicks.
    page.execute_script(<<~JS)
      document.querySelector("button[aria-label='Feedback / evidence actions']")?.click()
    JS
    page.execute_script(<<~JS)
      [...document.querySelectorAll("button")]
        .find((b) => b.textContent.trim() === "Request feedback / evidence")?.click()
    JS
    assert_selector "#evidence-request-modal-overlay", visible: true
    assert_text "Who can speak to this?"
  end

  should "offer the assessee themselves as a recipient (a manager can ask for more evidence)" do
    open_request_modal
    assert_selector "[data-request-evidence-target='suggestions'] button", text: "Report Alex (assessee)"
  end

  should "request evidence from a suggested peer and see it on the hub" do
    open_request_modal

    # The peer is a suggestion; clicking it selects them and enables Send.
    page.execute_script(<<~JS)
      [...document.querySelectorAll("#evidence-request-modal-overlay button")]
        .find((b) => b.textContent.includes("Pat Peer"))?.click()
    JS
    within "#evidence-request-modal-overlay" do
      assert_selector "[data-request-evidence-target='selected']", text: "Pat Peer"
      # Added recipients drop out of the suggestion list, and the button counts.
      assert_no_selector "[data-request-evidence-target='suggestions'] button", text: "Pat Peer", visible: true
      assert_selector "button[type='submit']", text: "Send 1 request"
      js_fill_in "evr-message", with: "Saw you pair on the incident"
    end

    # Submit via requestSubmit() — the pointer click on the modal's Send
    # button was dropped on a starved CI runner (modal still open at the
    # next assertion). See testing.md, "Inline-Editor Form Submits —
    # requestSubmit() Over Click".
    page.execute_script(<<~JS)
      document.querySelector("#evidence-request-modal-overlay button[type='submit']")
        .closest("form").requestSubmit()
    JS

    assert_text "Feedback request"
    ActsAsTenant.with_tenant(@tenant) do
      req = EvidenceRequest.where(requestee_person_id: @peer.id, person_id: @report.id).first
      assert_not_nil req
      assert_equal "pending", req.status
      assert_equal @cap_stable, req.capability_stable_id
    end
  end

  should "show the evidence-actions menu on mobile too" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit assessment_path(@report_assignment)
    assert_text "Critical Thinking"
    assert_selector "button[aria-label='Feedback / evidence actions']", visible: :all
  end
end
