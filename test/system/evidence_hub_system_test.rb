# frozen_string_literal: true

require "application_system_test_case"

class EvidenceHubSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    @report_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @report = create(:person, tenant: @tenant, email: @report_user.email, name: "Rep")
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      create(:tenant_user, tenant: @tenant, user: @report_user, person: @report, role: :member)
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "x")
      PersonDevelopment::CommandHandler.new.assign_to_framework(@report.id, @framework_id, role.role_id, level.level_id)
    end
  end

  def make_request!
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.request_evidence(@report.id, @framework_id, id,
        requested_by_id: @report.id, requestee_person_id: @peer.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Pairing notes?")
    end
    id
  end

  should "let the requestee respond with evidence" do
    make_request!
    sign_in_as(@peer_user)
    visit evidence_hub_path
    assert_text "Rep asked you for feedback"
    # The card is upfront that the response won't be private to the requester.
    assert_text "Your response will be visible to Rep, their managers, and workspace admins"

    # Open the unified modal in respond mode, fill it, and submit. JS-dispatch
    # the click so a starved CI event loop can't silently drop it (the trigger is
    # a Stimulus action, not a navigation).
    page.execute_script(
      "document.querySelector(\"button[data-evidence-modal-mode-param='respond']\").click()"
    )
    assert_selector "#evidence-modal-overlay", visible: true
    assert_selector "#evm-content", visible: true
    # The modal repeats the visibility disclosure where the response is written.
    assert_text "Your feedback will be added to Rep's assessment"

    # The judgment is a forced choice on every new link — without it the
    # required radio group blocks requestSubmit.
    page.execute_script(<<~JS)
      const f = document.querySelector("#evidence-modal form");
      f.querySelector("#evm-type").value = "peer_feedback";
      f.querySelector("#evm-title").value = "Incident retro";
      f.querySelector("#evm-content").value = "Strong systems thinking during the incident.";
      f.querySelector("#evm-url").value = "https://slack.example/archives/p1";
      f.querySelector("#evm-valence").value = "strongly_demonstrated";
      f.requestSubmit();
    JS

    assert_text "Feedback provided"
    ActsAsTenant.with_tenant(@tenant) do
      request = EvidenceRequest.last
      assert_equal "responded", request.status
      item = EvidenceItem.find(request.evidence_id)
      assert_equal "Incident retro", item.title
      assert_equal "https://slack.example/archives/p1", item.external_reference.url
      assert_equal "strongly_demonstrated", EvidenceLink.find_by(evidence_id: item.id).valence
    end
  end

  should "block the respond submit until a judgment is chosen" do
    make_request!
    sign_in_as(@peer_user)
    visit evidence_hub_path
    assert_text "Rep asked you for feedback"
    page.execute_script(
      "document.querySelector(\"button[data-evidence-modal-mode-param='respond']\").click()"
    )
    assert_selector "#evidence-modal-overlay", visible: true
    assert_selector "#evm-content", visible: true

    # Fill everything EXCEPT the valence — the required judgment select
    # keeps the form invalid, so a submit can't fire.
    valid = page.evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector("#evidence-modal form");
        f.querySelector("#evm-type").value = "peer_feedback";
        f.querySelector("#evm-content").value = "Filled but unjudged.";
        return f.checkValidity();
      })()
    JS
    assert_equal false, valid, "form must be invalid until a judgment is picked"
    ActsAsTenant.with_tenant(@tenant) { assert_equal "pending", EvidenceRequest.last.status }
  end

  should "let the requester cancel an outgoing request" do
    make_request!
    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "To Peer"

    auto_confirm { click_link "Cancel request" }
    assert_text "Request cancelled"
    ActsAsTenant.with_tenant(@tenant) { assert_equal "cancelled", EvidenceRequest.last.status }
  end

  should "show the request history on an open outgoing card" do
    make_request!
    ActsAsTenant.with_tenant(@tenant) do
      request = EvidenceRequest.last
      PersonDevelopment::CommandHandler.new.remind_evidence_request(
        request.person_id, request.framework_id, request.id, kind: "no_response"
      )
    end

    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "To Peer"
    within "[data-testid='request-history']" do
      assert_text(/Requested .* ago/)
      assert_text(/Reminder sent .* ago/)
    end
  end

  should "group requests into open and completed, incoming and outgoing" do
    make_request!
    declined = make_request!
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.decline_evidence_request(
        @report.id, @framework_id, declined, declined_by_id: @peer.id
      )
    end

    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "Open requests"
    assert_text "Completed requests"
    # One "Your requests" subsection under each group: the pending outgoing
    # card sits under Open, the declined one under Completed with its badge.
    assert_selector "h3", text: /Your requests/i, count: 2
    assert_text "Declined"
  end

  should "navigate from authored evidence to its linkage on the assessment" do
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.record_evidence(@report.id, @framework_id, SecureRandom.uuid_v7,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", content: "Shipped the migration", author_id: @report.id, valence: "demonstrated")
    end

    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "Shipped the migration"

    # The in-situ link deep-links into the assessment with the linked
    # capability focused; the evidence reads in place in the expanded card.
    click_link_with_js_fallback "View in assessment", expect_text: "Rate yourself to see your score"
    assert_selector "[data-focused='true']", text: "Critical Thinking"
    assert_text "Shipped the migration"
  end

  should "let the requester nudge a stale open request" do
    make_request!
    ActsAsTenant.with_tenant(@tenant) do
      EvidenceRequest.last.update_column(:requested_at, 3.days.ago)
    end

    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "To Peer"
    click_button_with_js_fallback "Send a nudge", expect_text: "Nudge sent to Peer"
    within "[data-testid='request-history']" do
      assert_text(/Nudged by Rep .* ago/)
    end
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "manual", EvidenceRequest.last.reminder_history.sole["kind"]
    end
  end
end
