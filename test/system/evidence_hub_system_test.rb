# frozen_string_literal: true

require "application_system_test_case"

class EvidenceHubSystemTest < ApplicationSystemTestCase
  include ContrastHelpers

  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
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

  def decline_modal_id(request_id)
    "decline-request-modal-#{request_id}"
  end

  def open_decline_modal(request_id)
    click_selector_with_js_fallback("button[data-modal-target-id='#{decline_modal_id(request_id)}']",
                                    expect_selector: "##{decline_modal_id(request_id)}")
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

    # The valence is a forced choice on every new link — without it the
    # required select blocks requestSubmit.
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

  should "block the respond submit until a valence is chosen" do
    make_request!
    sign_in_as(@peer_user)
    visit evidence_hub_path
    assert_text "Rep asked you for feedback"
    page.execute_script(
      "document.querySelector(\"button[data-evidence-modal-mode-param='respond']\").click()"
    )
    assert_selector "#evidence-modal-overlay", visible: true
    assert_selector "#evm-content", visible: true

    # Fill everything EXCEPT the valence — the required valence select
    # keeps the form invalid, so a submit can't fire.
    valid = page.evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector("#evidence-modal form");
        f.querySelector("#evm-type").value = "peer_feedback";
        f.querySelector("#evm-content").value = "Filled but unjudged.";
        return f.checkValidity();
      })()
    JS
    assert_equal false, valid, "form must be invalid until a valence is picked"
    ActsAsTenant.with_tenant(@tenant) { assert_equal "pending", EvidenceRequest.last.status }
  end

  should "let the requester cancel an outgoing request" do
    make_request!
    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "You asked Peer for feedback"

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
    assert_text "You asked Peer for feedback"
    within "[data-testid='request-history']" do
      assert_text(/Requested .* ago/)
      assert_text(/Reminder sent .* ago/)
    end
  end

  should "keep both requests in one thread, each answer after its ask" do
    make_request!
    declined = make_request!
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.decline_evidence_request(
        @report.id, @framework_id, declined, declined_by_id: @peer.id
      )
    end

    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_selector "[data-testid='conversation-row']", count: 1
    kinds = all("[data-testid='conversation-thread'] [data-testid='conversation-message']").map { |m| m["data-kind"] }
    assert_equal %w[request request declined], kinds
    assert_selector "[data-kind='declined'] [data-testid='reply-quote']", text: /You asked on/
  end

  should "let the requestee decline with a reason the requester can read" do
    request_id = make_request!
    sign_in_as(@peer_user)
    visit evidence_hub_path
    assert_no_field "Reason for declining (optional)"

    open_decline_modal(request_id)
    within("##{decline_modal_id(request_id)}") { assert_text "Rep will see your reason." }
    js_fill_in "Reason for declining (optional)", with: "Haven't worked with Rep this quarter"
    click_selector_with_js_fallback("##{decline_modal_id(request_id)} input[type='submit']",
                                    expect_text: "Request declined.")

    sign_in_as(@report_user)
    visit evidence_hub_path
    within("[data-kind='declined']") { assert_text "Haven't worked with Rep this quarter" }
  end

  should "keep a typed decline reason readable in dark mode" do
    request_id = make_request!
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ]
    )
    sign_in_as(@peer_user)
    visit evidence_hub_path
    open_decline_modal(request_id)
    js_fill_in "Reason for declining (optional)", with: "Haven't worked with Rep this quarter"

    assert_operator rendered_contrast("#decline-reason-#{request_id}"), :>=, 4.5
  ensure
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
    )
  end

  should "list feedback the viewer gave without a cell as not yet placed" do
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.record_evidence(@report.id, @framework_id, SecureRandom.uuid_v7,
        source: "peer", evidence_type: "peer_feedback", content: "Ran the incident call calmly.",
        author_id: @peer.id)
    end
    sign_in_as(@peer_user)
    visit evidence_hub_path
    within("[data-kind='feedback'][data-mine='true']") do
      assert_text "Not placed yet"
      assert_text "About Rep"
    end
    assert_no_text "Lnil"
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
    assert_text "You asked Peer for feedback"
    click_button_with_js_fallback "Send a nudge", expect_text: "Nudge sent to Peer"
    within "[data-testid='request-history']" do
      assert_text(/Nudged by you .* ago/)
    end
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "manual", EvidenceRequest.last.reminder_history.sole["kind"]
    end
  end

  context "conversations" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @lead = create(:person, tenant: @tenant, name: "Lena Lead")
        handler = PersonDevelopment::CommandHandler.new
        (1..12).each do |n|
          travel_to(n.hours.ago) do
            handler.record_evidence(@report.id, @framework_id, SecureRandom.uuid_v7,
              capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "peer", valence: "demonstrated",
              evidence_type: "peer_feedback", content: "Pairing note #{13 - n}.", author_id: @peer.id)
          end
        end
        travel_to(2.days.ago) do
          handler.record_evidence(@report.id, @framework_id, SecureRandom.uuid_v7,
            capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "peer", valence: "demonstrated",
            evidence_type: "peer_feedback", content: "From Lena.", author_id: @lead.id)
        end
      end
    end

    should "open the newest thread on its newest message, on desktop" do
      sign_in_as(@report_user)
      visit evidence_hub_path
      assert_selector "[data-testid='conversation-row']", count: 2
      assert_equal [ @peer.id, @lead.id ], all("[data-testid='conversation-row']").map { |r| r["data-person-id"] }
      wait_for_stimulus "conversation-thread"
      at_bottom = page.evaluate_script(<<~JS)
        (() => {
          const body = document.querySelector("[data-conversation-thread-target='body']");
          return body.scrollHeight > body.clientHeight && body.scrollTop + body.clientHeight >= body.scrollHeight - 2;
        })()
      JS
      assert at_bottom, "the thread should open scrolled to its newest message"
    end

    should "narrow the list to the names typed" do
      sign_in_as(@report_user)
      visit evidence_hub_path
      wait_for_stimulus "conversation-search"
      js_fill_in "Search people", with: "len"
      assert_selector "[data-testid='conversation-row']", count: 1
      assert_selector "[data-testid='conversation-row'][data-person-id='#{@lead.id}']"
      js_fill_in "Search people", with: "zzz"
      assert_text "No one matches that name."
    end

    should "show the list, then the thread on its own screen, on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@report_user)
      visit evidence_hub_path
      assert_selector "[data-testid='conversation-list']", visible: true
      assert_no_selector "[data-testid='conversation-thread']", visible: true

      click_selector_with_js_fallback("[data-testid='conversation-row'][data-person-id='#{@lead.id}']",
                                      expect_selector: "[data-testid='conversation-thread'] h2")
      assert_selector "[data-testid='conversation-thread'] h2", text: "Lena Lead", visible: true
      assert_no_selector "[data-testid='conversation-list']", visible: true
      assert_no_selector "#needs-you", visible: true
      assert_no_sideways_overflow

      click_link_with_js_fallback "Conversations", expect_text: "What needs you"
      assert_selector "[data-testid='conversation-list']", visible: true
    end

    should "keep a long thread's header on screen as it scrolls, on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@report_user)
      visit evidence_conversation_path(@peer.id)
      assert_selector "[data-testid='conversation-header']", text: "Peer", visible: true
      assert page.evaluate_script("document.documentElement.scrollHeight > window.innerHeight * 2"), "the thread should be long"

      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight / 2)")
      header_top = page.evaluate_script(
        "document.querySelector(\"[data-testid='conversation-header']\").getBoundingClientRect().top"
      )
      assert_operator header_top, :>=, 0, "the header, with its way back, should stay on screen"
    end

    should "follow an old notification anchor to the thread that holds the item" do
      item_id = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find_by!(content: "From Lena.").id }
      sign_in_as(@report_user)
      visit "#{evidence_hub_path}##{EvidenceItem.dom_id(item_id)}"
      assert_selector "[data-testid='conversation-thread'] h2", text: "Lena Lead"
      assert_current_path evidence_conversation_path(@lead.id)
      assert_equal "##{EvidenceItem.dom_id(item_id)}", page.evaluate_script("window.location.hash")
    end
  end
end
