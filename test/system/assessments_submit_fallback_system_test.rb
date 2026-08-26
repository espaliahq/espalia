# frozen_string_literal: true

require "application_system_test_case"

# Transport-level write failures must be visible (audit issue #316): a 5xx or
# network failure on a rating or evidence submit previously produced no
# feedback at all (rating), or replaced the whole page with the raw error
# body (evidence modal). The submit-fallback controller surfaces a retryable
# inline error in a pre-existing live region and, for non-stream error
# responses, claims them before Turbo renders them as a page.
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
