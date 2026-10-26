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

  # `patch_fetch` is shared — test/support/system/fetch_stub_helpers.rb.
  #
  # Click the cell's Request button. JS-dispatch so a starved CI loop can't
  # drop the Stimulus click.
  def trigger_request_modal
    page.execute_script(<<~JS)
      document.querySelector("button[data-request-evidence-assignment-id-param]")?.click()
    JS
  end

  # The frame-load error state's Retry / Close, dispatched by label.
  def click_modal_error_button(label)
    page.execute_script(<<~JS)
      [...document.querySelectorAll("#evidence-request-modal-error button")]
        .find((b) => b.textContent.trim() === #{label.to_json})
        .click();
    JS
  end

  # Visit the report's assessment and open the request modal, synced on its
  # loaded form.
  private def open_request_modal
    visit assessment_path(@report_assignment)
    assert_text "Critical Thinking"
    trigger_request_modal
    assert_selector "#evidence-request-modal-overlay", visible: true
    assert_text "Who can speak to this?"
  end

  # Select the peer suggestion chip, which enables Send and counts it.
  def select_peer_suggestion
    page.execute_script(<<~JS)
      [...document.querySelectorAll("#evidence-request-modal-overlay button")]
        .find((b) => b.textContent.includes("Pat Peer"))?.click()
    JS
    assert_selector "#evidence-request-modal-overlay button[type='submit']", text: "Send 1 request"
  end

  # JS-dispatched Send click (testing.md: pointer clicks drop on starved CI).
  private def click_send
    page.execute_script(
      "document.querySelector(\"#evidence-request-modal-overlay button[type='submit']\").click();"
    )
  end

  # One user action, one request (audit issue #335). This write is NOT
  # idempotent — RequestEvidence mints a fresh request_id per POST — so a
  # second submission that lands means duplicate requests and duplicate
  # notifications for every recipient.
  should "lock Send in flight and send exactly one request per click" do
    open_request_modal
    select_peer_suggestion
    wait_for_stimulus "submit-guard"

    patch_fetch("/evidence_requests", respond: :delay)
    click_send

    # The POST is genuinely still open — held by the patch, not by a sleep.
    assert_selector "#evidence-request-modal-overlay button[type='submit'][disabled]",
      text: "Sending…", visible: true

    # A second attempt — a click on the locked button AND a programmatic
    # submit that bypasses it — must not reach the server. Both dispatch
    # synchronously, so the count is settled the moment they return.
    click_send
    page.execute_script(
      "document.querySelector(\"#evidence-request-modal-overlay form\").requestSubmit();"
    )
    assert_fetch_matched 1

    # Release the held POST: it lands, and it landed once.
    page.execute_script("window.__releaseFetch();")
    assert_text "Feedback request"
    assert_equal 1, page.evaluate_script("window.__matched")

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal 1, EvidenceRequest.where(requestee_person_id: @peer.id, person_id: @report.id).count
    end
  end

  # Audit issue #316 on this modal: a transport-level failure on Send was
  # completely silent — the guard unlocked the button and nothing else changed,
  # so "did it send?" was unanswerable — and a 5xx HTML body would have been
  # rendered as the page, destroying the recipients and message just assembled.
  should "surface a transport failure on Send and recover on retry" do
    open_request_modal
    select_peer_suggestion
    wait_for_stimulus "submit-guard"

    patch_fetch("/evidence_requests", respond: :reject)
    click_send

    # The modal stays, the failure is named, and the button is usable again.
    assert_selector "#evidence-request-modal-overlay [data-submit-fallback-target='message']",
      text: "Couldn't send your request", visible: true
    assert_selector "#evidence-request-modal-overlay", visible: true
    assert_selector "#evidence-request-modal-overlay button[type='submit']:not([disabled])",
      text: "Send 1 request", visible: true

    # And the retry genuinely goes through — one request, not two.
    page.execute_script("window.__unpatchFetch();")
    click_send

    assert_text "Feedback request"
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal 1, EvidenceRequest.where(requestee_person_id: @peer.id, person_id: @report.id).count
    end
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

  # The #328 failure mode on this modal (audit issue #365): a failed frame GET
  # used to leave "Loading…" standing forever — and with no exit at all, since
  # this modal's own × lives inside the frame that never loaded.
  context "the request modal's frame failing to load" do
    setup do
      visit assessment_path(@report_assignment)
      assert_text "Critical Thinking"
      wait_for_stimulus "frame-error"
    end

    should "surface a retryable error rather than a stuck Loading… state" do
      patch_fetch("evidence_request_modal", respond: :reject, once: true)
      trigger_request_modal

      assert_selector "#evidence-request-modal-overlay", visible: true
      assert_selector "#evidence-request-modal-error",
        text: "Couldn't load the request form", visible: true
      # The stuck placeholder is gone, not merely joined by an error.
      assert_no_selector "turbo-frame#evidence-request-modal", visible: true

      click_modal_error_button "Retry"

      assert_text "Who can speak to this?"
      assert_no_selector "#evidence-request-modal-error", visible: true
    end

    # A non-HTML body (a proxy's text/plain 502) makes `responseHTML` resolve
    # undefined, so Turbo renders nothing AND dispatches nothing — neither
    # frame-missing nor fetch-request-error. Only `responseReceived` catches it.
    should "surface a non-HTML failure Turbo discards without any event" do
      patch_fetch("evidence_request_modal", once: true,
        respond: "502 Bad Gateway", content_type: "text/plain")
      trigger_request_modal

      assert_selector "#evidence-request-modal-error",
        text: "Couldn't load the request form", visible: true
      assert_no_text "502 Bad Gateway"

      click_modal_error_button "Retry"

      assert_text "Who can speak to this?"
    end

    should "offer a Close that dismisses the modal" do
      patch_fetch("evidence_request_modal", respond: :reject, once: true)
      trigger_request_modal

      assert_selector "#evidence-request-modal-error",
        text: "Couldn't load the request form", visible: true

      click_modal_error_button "Close"

      assert_no_selector "#evidence-request-modal-overlay", visible: true
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    should "show Request beside Add without a hover on #{label}" do
      page.driver.browser.manage.window.resize_to(*size)
      visit assessment_path(@report_assignment, capability: @cap_stable, level_ordinal: 2)
      assert_selector "button[data-request-evidence-assignment-id-param]", text: "Request", visible: true
      assert_selector "button[data-evidence-modal-mode-param='new']", text: "Add", visible: true
      assert_no_stolen_taps
    end
  end
end
