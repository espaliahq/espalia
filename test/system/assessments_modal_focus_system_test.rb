# frozen_string_literal: true

require "application_system_test_case"

# Keyboard focus management for modals (audit issue #317, APG dialog
# contract): focus moves INTO the dialog on open (panel first, then the
# first field once the lazy frame lands), Tab and Shift+Tab wrap within the
# open overlay, and focus returns to the invoker on close — falling back to
# the kebab trigger when the invoking menu item is hidden with its dropdown.
class AssessmentsModalFocusSystemTest < ApplicationSystemTestCase
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

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first

      @manager_user = FactoryBot.create(:user, password: "password123")
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email,
        name: "Morgan Manager")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person.update!(manager: @manager)
    end

    sign_in_as(@user)
  end

  # Opens the unified evidence modal via the kebab and waits for the lazy
  # frame's form to render.
  def open_evidence_modal
    visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
    wait_for_stimulus "evidence-modal"
    assert_selector "[data-evidence-modal-mode-param='new']", visible: :all
    page.execute_script(
      "document.querySelector(\"[data-evidence-modal-mode-param='new']\").click();"
    )
    assert_selector "#evidence-modal-overlay", visible: true
    assert_selector "#evm-content", visible: true
  end

  def active_in_overlay?
    page.evaluate_script(
      "document.getElementById('evidence-modal-overlay').contains(document.activeElement)"
    )
  end

  context "opening the evidence modal" do
    should "move focus into the dialog and onto the first field once loaded" do
      open_evidence_modal
      # The frame has rendered; focus must sit inside the dialog, on a field.
      # The turbo:frame-load focus handler runs just after #evm-content
      # appears — poll briefly rather than racing it.
      assert active_in_overlay?, "focus should be inside the open dialog"
      deadline = Time.zone.now + 5
      focused_id = nil
      loop do
        focused_id = page.evaluate_script("document.activeElement.id")
        break if focused_id == "evm-type" || Time.zone.now > deadline
        sleep 0.1
      end
      assert_equal "evm-type", focused_id
    end
  end

  context "tabbing at the dialog edges" do
    should "wrap Tab from the last element to the first and Shift+Tab back" do
      open_evidence_modal
      page.execute_script(<<~JS)
        const overlay = document.getElementById("evidence-modal-overlay");
        const els = [...overlay.querySelectorAll(
          "a[href], button:not(:disabled), input:not([type='hidden']):not(:disabled), " +
          "select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex='-1'])"
        )].filter(el => el.offsetParent !== null);
        window.__first = els[0]; window.__last = els[els.length - 1];
        window.__last.focus();
      JS
      find("body").send_keys(:tab)
      assert page.evaluate_script("document.activeElement === window.__first"),
        "Tab from the last element should wrap to the first"

      page.execute_script("window.__first.focus();")
      find("body").send_keys([ :shift, :tab ])
      assert page.evaluate_script("document.activeElement === window.__last"),
        "Shift+Tab from the first element should wrap to the last"

      # From a non-tabbable in-dialog stop (the tabindex=-1 panel) default
      # traversal would exit backwards — the trap must catch that too.
      page.execute_script(
        "document.querySelector(\"#evidence-modal-overlay [data-modal-target='panel']\").focus();"
      )
      find("body").send_keys([ :shift, :tab ])
      assert page.evaluate_script("document.activeElement === window.__last"),
        "Shift+Tab from the panel should wrap to the last element"
      assert active_in_overlay?, "focus never leaves the open dialog"
    end
  end

  context "closing the dialog" do
    should "return focus to the visible invoker (the kebab for menu items)" do
      open_evidence_modal
      page.execute_script(<<~JS)
        const overlay = document.getElementById("evidence-modal-overlay");
        ([...overlay.querySelectorAll("button")].find(b => b.textContent.trim() === "Cancel")
          || overlay.querySelector("[data-action*='modal#close']")).click();
      JS
      assert_no_selector "#evidence-modal-overlay", visible: true
      # The return is deferred two animation frames (it must outlive the
      # response's Turbo Streams) — poll briefly rather than racing it.
      returned = false
      deadline = Time.zone.now + 5
      until returned || Time.zone.now > deadline
        returned = page.evaluate_script(
          "document.activeElement === document.querySelector(\"[aria-label='Feedback / evidence actions']\")"
        )
        sleep 0.1 unless returned
      end
      unless returned
        # CI-only failure — capture where focus actually went so the log is
        # diagnosable (this has never reproduced locally).
        diag = page.evaluate_script(<<~JS)
          (() => {
            const a = document.activeElement;
            const k = document.querySelector("[aria-label='Feedback / evidence actions']");
            return JSON.stringify({
              activeTag: a?.tagName, activeId: a?.id || null,
              activeAria: a?.getAttribute?.("aria-label") || null,
              activeText: (a?.textContent || "").trim().slice(0, 40),
              kebabExists: !!k, kebabVisible: k ? k.offsetParent !== null : null,
              kebabCount: document.querySelectorAll("[aria-label='Feedback / evidence actions']").length,
              overlayHidden: document.getElementById("evidence-modal-overlay")?.classList?.contains("hidden")
            });
          })()
        JS
        flunk "focus should return to the kebab that opened the menu — #{diag}"
      end
    end

    should "return focus to a standalone trigger that survives the close" do
      sign_in_as(@manager_user)
      visit assessment_path(@assignment)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      assert_selector "button", text: "Delegates", visible: true

      page.execute_script(
        "[...document.querySelectorAll('button')].find(b => b.textContent.trim().startsWith('Delegates')).click();"
      )
      # Wait for the modal's rendered content (the intro copy) — asserting on
      # a dialog-role selector can match a still-hidden overlay.
      assert_text "Delegates can record manager ratings"
      # Close via the × — the Delegates button survives in the header.
      page.execute_script(<<~JS)
        const overlay = [...document.querySelectorAll("[data-modal-target='overlay']")]
          .find(o => !o.classList.contains("hidden"));
        overlay.querySelector("[aria-label='Close']").click();
      JS

      returned = false
      deadline = Time.zone.now + 5
      until returned || Time.zone.now > deadline
        returned = page.evaluate_script(
          "document.activeElement === [...document.querySelectorAll('button')].find(b => b.textContent.trim().startsWith('Delegates'))"
        )
        sleep 0.1 unless returned
      end
      assert returned, "focus should return to the surviving Delegates trigger"
    end

    should "leave focus in a modal opened right after another closed" do
      open_evidence_modal
      # Close the evidence modal and immediately open the request modal —
      # the deferred corrective restore must not pull focus back out.
      page.execute_script(<<~JS)
        const overlay = document.getElementById("evidence-modal-overlay");
        ([...overlay.querySelectorAll("button")].find(b => b.textContent.trim() === "Cancel")
          || overlay.querySelector("[data-action*='modal#close']")).click();
        document.querySelector("[data-modal-target-id='evidence-request-modal-overlay']").click();
      JS
      assert_selector "#evidence-request-modal-overlay", visible: true
      assert_selector "#evr-message", visible: true
      sleep 0.3 # outlive the 60ms corrective-restore window
      assert page.evaluate_script(
        "document.getElementById('evidence-request-modal-overlay').contains(document.activeElement)"
      ), "focus must stay inside the newer dialog"
    end
  end
end
