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

    # Open the unified modal in respond mode, fill it, and submit. JS-dispatch
    # the click so a starved CI event loop can't silently drop it (the trigger is
    # a Stimulus action, not a navigation).
    page.execute_script(
      "document.querySelector(\"button[data-evidence-modal-mode-param='respond']\").click()"
    )
    assert_selector "#evidence-modal-overlay", visible: true
    assert_selector "#evm-content", visible: true

    page.execute_script(<<~JS)
      const f = document.querySelector("#evidence-modal form");
      f.querySelector("#evm-type").value = "peer_feedback";
      f.querySelector("#evm-title").value = "Incident retro";
      f.querySelector("#evm-content").value = "Strong systems thinking during the incident.";
      f.querySelector("#evm-url").value = "https://slack.example/archives/p1";
      f.requestSubmit();
    JS

    assert_text "Feedback provided"
    ActsAsTenant.with_tenant(@tenant) do
      request = EvidenceRequest.last
      assert_equal "responded", request.status
      item = EvidenceItem.find(request.evidence_id)
      assert_equal "Incident retro", item.title
      assert_equal "https://slack.example/archives/p1", item.external_reference.url
    end
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

  should "let the requester nudge a stale open request" do
    make_request!
    ActsAsTenant.with_tenant(@tenant) do
      EvidenceRequest.last.update_column(:requested_at, 3.days.ago)
    end

    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "To Peer"
    click_button "Send a nudge"
    assert_text "Nudge sent to Peer"
    within "[data-testid='request-history']" do
      assert_text(/Nudged by Rep .* ago/)
    end
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "manual", EvidenceRequest.last.reminder_history.sole["kind"]
    end
  end
end
