# frozen_string_literal: true

require "application_system_test_case"

# Transport-level write failures must be visible (audit issue #316): a 5xx or
# network failure on a rating or evidence submit previously produced no
# feedback at all (rating), or replaced the whole page with the raw error
# body (evidence modal). The submit-fallback controller surfaces a retryable
# inline error in a pre-existing live region and, for non-stream error
# responses, claims them before Turbo renders them as a page.
#
# The same "a failed request must be visible and recoverable" rule covers the
# evidence modal's lazy frame LOAD (audit issue #328): a failed GET used to
# leave the modal on "Loading…" forever, with no error and no way forward.
class AssessmentsSubmitFallbackSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      @level_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer 1", "E1", is_entry: true)

      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)

      cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, cap_id, @cap_stable, cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cap_id, 1,
        "Synthesises information"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  # Patches window.fetch to answer 500 (text/html body — the page-destroying
  # class) for URLs containing the given fragment. A page reload clears it.
  def patch_fetch_to_fail(url_fragment)
    page.execute_script(<<~JS)
      const of = window.fetch;
      window.__unpatchFetch = () => { window.fetch = of; };
      window.fetch = (url, ...a) => String(url).includes(#{url_fragment.to_json})
        ? Promise.resolve(new Response("<html><body>Internal Server Error</body></html>",
            { status: 500, headers: { "Content-Type": "text/html" } }))
        : of(url, ...a);
    JS
  end

  # Patches window.fetch to fail only the FIRST request matching the fragment,
  # then pass everything through — so a retry can succeed. `body` nil rejects
  # the promise (network layer); a String answers 500 with that HTML body (the
  # response-carries-no-frame layer); `content_type` switches the response to
  # a body Turbo will not even try to render (the silent-discard layer).
  def patch_fetch_to_fail_once(url_fragment, body: nil, content_type: "text/html")
    failure = if body
      "Promise.resolve(new Response(#{body.to_json}, " \
        "{ status: 500, headers: { \"Content-Type\": #{content_type.to_json} } }))"
    else
      'Promise.reject(new TypeError("Failed to fetch"))'
    end
    page.execute_script(<<~JS)
      const of = window.fetch;
      let spent = false;
      window.fetch = (url, ...a) => {
        if (!spent && String(url).includes(#{url_fragment.to_json})) {
          spent = true;
          return #{failure};
        }
        return of(url, ...a);
      };
    JS
  end

  # Patches window.fetch to count and delay requests matching the fragment, so
  # a second submission can be attempted while the first is still in flight.
  def patch_fetch_to_delay(url_fragment, ms: 2000)
    page.execute_script(<<~JS)
      const of = window.fetch;
      window.__matched = 0;
      window.fetch = (url, ...a) => {
        if (!String(url).includes(#{url_fragment.to_json})) return of(url, ...a);
        window.__matched++;
        return new Promise((resolve, reject) => {
          setTimeout(() => of(url, ...a).then(resolve, reject), #{ms});
        });
      };
    JS
  end

  def open_evidence_modal
    page.execute_script(
      "document.querySelector(\"[data-evidence-modal-mode-param='new']\").click();"
    )
  end

  # The frame-load error state's Retry / Close, dispatched by label.
  def click_modal_error_button(label)
    page.execute_script(<<~JS)
      [...document.querySelectorAll("#evidence-modal-error button")]
        .find((b) => b.textContent.trim() === #{label.to_json})
        .click();
    JS
  end

  def fill_evidence_form(text)
    js_fill_in "#evm-content", with: text
    js_fill_in "#evm-valence", with: "demonstrated"
  end

  def submit_evidence_form
    page.execute_script(
      "document.querySelector('#evidence-modal-overlay button[type=submit]').click();"
    )
  end

  context "the evidence modal's frame failing to load" do
    setup do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "evidence-modal"
    end

    should "surface a retryable error rather than a stuck Loading… state" do
      patch_fetch_to_fail_once("/evidence_modal")
      open_evidence_modal

      assert_selector "#evidence-modal-overlay", visible: true
      assert_selector "#evidence-modal-error", text: "Couldn't load the form", visible: true
      # The stuck placeholder is gone, not merely joined by an error.
      assert_no_selector "turbo-frame#evidence-modal", visible: true

      # Retry recovers: the form lands and the error clears.
      click_modal_error_button "Retry"

      assert_selector "textarea#evm-content", visible: true
      assert_no_selector "#evidence-modal-error", visible: true
    end

    should "keep the modal when the response carries no frame" do
      patch_fetch_to_fail_once("/evidence_modal",
        body: "<html><body>Internal Server Error</body></html>")
      open_evidence_modal

      # turbo:frame-missing's un-prevented default renders Turbo's own
      # "Content missing" into the frame and throws; cancelling it keeps our
      # error state instead. Either way the raw 500 body must never surface.
      assert_selector "#evidence-modal-error", text: "Couldn't load the form", visible: true
      assert_selector "#evidence-modal-overlay", visible: true
      assert_no_text "Internal Server Error"

      click_modal_error_button "Retry"

      assert_selector "textarea#evm-content", visible: true
    end

    # The silent layer: a non-HTML body (a proxy's text/plain 502) makes
    # `FetchResponse#responseHTML` resolve undefined, so Turbo's `loadResponse`
    # returns having rendered nothing AND dispatched nothing — no
    # frame-missing, no fetch-request-error. Only `responseReceived` catches it.
    should "surface a non-HTML failure Turbo discards without any event" do
      patch_fetch_to_fail_once("/evidence_modal",
        body: "502 Bad Gateway", content_type: "text/plain")
      open_evidence_modal

      assert_selector "#evidence-modal-error", text: "Couldn't load the form", visible: true
      assert_no_selector "turbo-frame#evidence-modal", visible: true
      assert_no_text "502 Bad Gateway"

      click_modal_error_button "Retry"

      assert_selector "textarea#evm-content", visible: true
      assert_no_selector "#evidence-modal-error", visible: true
    end

    # Retry is not the only way out: the form's own ×/Cancel went down with
    # the hidden frame, so the error state carries the exit itself.
    should "offer a Close that dismisses the modal" do
      patch_fetch_to_fail_once("/evidence_modal")
      open_evidence_modal

      assert_selector "#evidence-modal-error", text: "Couldn't load the form", visible: true

      click_modal_error_button "Close"

      assert_no_selector "#evidence-modal-overlay", visible: true
    end
  end

  # One user action, one request (audit issue #335): the modal's submit button
  # is disabled for the duration of the write, and a re-entrant submit while
  # one is in flight never reaches the server.
  context "submitting the evidence modal" do
    setup do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "evidence-modal"
      open_evidence_modal
      assert_selector "textarea#evm-content", visible: true
      wait_for_stimulus "submit-guard"
    end

    should "lock the submit button in flight and send exactly one save" do
      patch_fetch_to_delay("/evidence/save")
      fill_evidence_form("Feedback worth keeping")
      submit_evidence_form

      assert_selector "#evidence-modal-overlay button[type=submit][disabled]",
        text: "Saving…", visible: true

      # A second attempt — a click on the locked button AND a programmatic
      # submit that bypasses it — must not reach the server.
      submit_evidence_form
      page.execute_script("document.querySelector('#evidence-modal-overlay form').requestSubmit();")

      assert_text "Feedback worth keeping"
      assert_equal 1, page.evaluate_script("window.__matched")
    end

    should "unlock the submit button when the save fails, so it can be retried" do
      patch_fetch_to_fail("/evidence/save")
      fill_evidence_form("Feedback worth keeping")
      submit_evidence_form

      assert_selector "#evidence-modal-overlay [data-submit-fallback-target='message']",
        text: "Couldn't save your feedback", visible: true
      assert_selector "#evidence-modal-overlay button[type=submit]:not([disabled])",
        text: "Add feedback / evidence", visible: true

      # And the retry genuinely goes through.
      page.execute_script("window.__unpatchFetch();")
      submit_evidence_form
      assert_text "Feedback worth keeping"
    end
  end

  context "rating submit failing at the transport layer" do
    should "surface a retryable inline error and recover on retry" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "submit-fallback", scope: "#rating-#{@cap_stable}-1"

      patch_fetch_to_fail("/ratings")
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        wrapper.querySelector("[data-dropdown-target='trigger']").click();
      JS
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        [...wrapper.querySelectorAll("button[type=submit]")]
          .find(b => b.textContent.includes("Consistently")).click();
      JS

      assert_selector "#rating-#{@cap_stable}-1 [data-submit-fallback-target='message']",
        text: "Couldn't save this rating", visible: true
      # The pill is untouched — no phantom rating.
      assert_selector "#rating-#{@cap_stable}-1 [aria-label='Rated not rated — change']", visible: :all

      # Retry with the network back: the rating lands and the message clears.
      page.execute_script("window.__unpatchFetch();")
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        wrapper.querySelector("[data-dropdown-target='trigger']").click();
      JS
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        [...wrapper.querySelectorAll("button[type=submit]")]
          .find(b => b.textContent.includes("Consistently")).click();
      JS

      assert_selector "#rating-#{@cap_stable}-1 [aria-label='Rated consistently — change']", visible: :all
      assert_no_selector "#rating-#{@cap_stable}-1 [data-submit-fallback-target='message']",
        text: "Couldn't save", visible: true
    end
  end

  context "rating submit failing at the network layer (fetch rejects)" do
    should "surface the connection error and recover on retry" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "submit-fallback", scope: "#rating-#{@cap_stable}-1"

      page.execute_script(<<~JS)
        const of = window.fetch;
        window.__unpatchFetch = () => { window.fetch = of; };
        window.fetch = (url, ...a) => String(url).includes("/ratings")
          ? Promise.reject(new TypeError("Failed to fetch"))
          : of(url, ...a);
      JS
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        wrapper.querySelector("[data-dropdown-target='trigger']").click();
      JS
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        [...wrapper.querySelectorAll("button[type=submit]")]
          .find(b => b.textContent.includes("Consistently")).click();
      JS

      assert_selector "#rating-#{@cap_stable}-1 [data-submit-fallback-target='message']",
        text: "check your connection", visible: true
      assert_selector "#rating-#{@cap_stable}-1 [aria-label='Rated not rated — change']", visible: :all

      page.execute_script("window.__unpatchFetch();")
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        wrapper.querySelector("[data-dropdown-target='trigger']").click();
      JS
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("#rating-#{@cap_stable}-1 [data-controller~='submit-fallback']");
        [...wrapper.querySelectorAll("button[type=submit]")]
          .find(b => b.textContent.includes("Consistently")).click();
      JS

      assert_selector "#rating-#{@cap_stable}-1 [aria-label='Rated consistently — change']", visible: :all
    end
  end

  context "evidence submit failing at the transport layer" do
    should "keep the page and typed text, show the error, and recover on retry" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "evidence-modal"

      page.execute_script(
        "document.querySelector(\"[data-evidence-modal-mode-param='new']\").click();"
      )
      assert_selector "#evidence-modal-overlay", visible: true
      assert_selector "#evm-content", visible: true

      patch_fetch_to_fail("/evidence/save")
      page.execute_script(<<~JS)
        const ta = document.querySelector("#evm-content");
        ta.value = "Feedback worth keeping";
        ta.dispatchEvent(new Event("input", { bubbles: true }));
        const v = document.querySelector("#evm-valence");
        if (v) { v.value = "demonstrated"; v.dispatchEvent(new Event("change", { bubbles: true })); }
        document.querySelector("#evidence-modal-overlay form").requestSubmit();
      JS

      # The 500 HTML body must NOT be rendered as the page; the modal stays,
      # the message shows, the text survives.
      assert_selector "#evidence-modal-overlay [data-submit-fallback-target='message']",
        text: "Couldn't save your feedback", visible: true
      assert_selector "#evidence-modal-overlay", visible: true
      assert_equal "Feedback worth keeping",
        page.evaluate_script("document.querySelector('#evm-content').value")

      # Closing and reopening must not resurrect the stale error banner.
      page.execute_script(
        "document.querySelector(\"#evidence-modal-overlay [data-action*='modal#close']\")?.click()" \
          " || document.querySelector(\"#evidence-modal-overlay button[aria-label='Close']\").click();"
      )
      assert_no_selector "#evidence-modal-overlay", visible: true
      page.execute_script(
        "document.querySelector(\"[data-evidence-modal-mode-param='new']\").click();"
      )
      assert_selector "#evidence-modal-overlay", visible: true
      assert_no_selector "#evidence-modal-overlay [data-submit-fallback-target='message']",
        text: "Couldn't save", visible: true

      # Retry with the network back: saved, modal closed, item on the card.
      # The reopen reloads the lazy frame — wait for the FRESH (empty) form,
      # or on a starved runner the fill lands on the old form the frame is
      # about to replace.
      assert_selector "textarea#evm-content", visible: true
      assert page.has_field?("evm-content", with: "", wait: 10),
        "reopened evidence form should start empty"
      page.execute_script("window.__unpatchFetch();")
      page.execute_script(<<~JS)
        const ta = document.querySelector("#evm-content");
        ta.value = "Feedback worth keeping";
        ta.dispatchEvent(new Event("input", { bubbles: true }));
        const v = document.querySelector("#evm-valence");
        if (v) { v.value = "demonstrated"; v.dispatchEvent(new Event("change", { bubbles: true })); }
        document.querySelector("#evidence-modal-overlay form").requestSubmit();
      JS

      assert_text "Feedback worth keeping"
      assert_no_selector "#evidence-modal-overlay", visible: true
    end
  end
end
