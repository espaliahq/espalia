# frozen_string_literal: true

require "application_system_test_case"

# Edit mode on a phone (issue #384).
#
# View mode always had a responsive contract — the role tree is a slide-over
# below `lg` and the matrix takes the width. Edit mode never got one: it added
# a second `w-80` column that was rendered OPEN, so at 375 px the activity pane
# took 320 px and the matrix was a 55 px sliver reading "C" of "CAPABILITY",
# while the header's mode toggle, "Exit edit mode", Publish and Settings ran
# off the right edge and took the whole document with them
# (`scrollWidth` 825 vs `clientWidth` 375).
#
# What these pin, at both viewports:
#
#  - nothing but the matrix scrolls horizontally;
#  - every header control the criteria name is reachable without scrolling;
#  - the activity pane is an overlay below `lg` (closed by default, opened by
#    the Activity stat, closed by an outside tap or Esc) and an inline column
#    above it;
#  - the review actions the phone is FOR — the feed, its entries, and the
#    modals they open — still work from that overlay.
class Frameworks::MobileEditModeSystemTest < ApplicationSystemTestCase
  LEVEL_COUNT = 4

  # One round trip for every geometry question the criteria ask. Rounded, so a
  # sub-pixel layout can't make an exact comparison flake.
  LAYOUT_PROBE_JS = <<~JS
    (() => {
      const de = document.documentElement;
      const rect = (el) => {
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { left: Math.round(r.left), right: Math.round(r.right),
                 width: Math.round(r.width), bottom: Math.round(r.bottom) };
      };
      const byText = (sel, text) =>
        Array.from(document.querySelectorAll(sel))
             .find((e) => e.textContent.includes(text));
      const pane = document.querySelector("[data-framework-explorer-target='contextPane']");
      const headers = Array.from(document.querySelectorAll("#framework-matrix thead th"));

      return {
        scrollWidth: de.scrollWidth,
        clientWidth: de.clientWidth,
        main: rect(document.querySelector("[data-matrix-target='scrollContainer']")),
        pane: rect(pane),
        paneDisplay: pane ? getComputedStyle(pane).display : null,
        panePosition: pane ? getComputedStyle(pane).position : null,
        // The header controls the acceptance criteria name, by their own
        // rendered right edges — the failure mode was "present but off-screen".
        controls: {
          editing: rect(byText("button[data-edit-mode-value]", "Editing")),
          suggesting: rect(byText("button[data-edit-mode-value]", "Suggesting")),
          exit: rect(byText("a", "Exit edit mode")),
          activity: rect(document.querySelector("[data-framework-explorer-target='contextPaneToggle']")),
          search: rect(document.querySelector("input[type='search']"))
        },
        // The first two columns: the sticky capability column and the first
        // level. Both must start inside the viewport.
        capabilityColumn: rect(headers[0]),
        firstLevelColumn: rect(headers[1])
      };
    })()
  JS

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "A Deliberately Long Career Framework Name")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      LEVEL_COUNT.times do |i|
        handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, i + 1,
                          "Engineer #{i + 1}", "E#{i + 1}", is_entry: i.zero?)
      end
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, rid)
      LEVEL_COUNT.times do |i|
        handler.set_behavioural_expectation(
          @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, i + 1,
          "Asks clarifying questions at level #{i + 1}"
        )
      end
      handler.publish_version(@framework_id, "test")
    end
  end

  context "edit mode at 375x812" do
    setup do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
      wait_for_stimulus "framework-explorer"
    end

    should "not scroll the document sideways, and keep every header control on screen" do
      layout = page.evaluate_script(LAYOUT_PROBE_JS)

      assert_equal layout["clientWidth"], layout["scrollWidth"],
                   "the page scrolls horizontally — only the matrix pane may"

      layout["controls"].each do |name, rect|
        assert rect, "#{name} did not render"
        assert_operator rect["left"], :>=, 0, "#{name} starts left of the viewport"
        assert_operator rect["right"], :<=, layout["clientWidth"],
                        "#{name} extends past the right edge of the viewport"
      end
    end

    should "give the matrix the full width, showing the capability and a level column" do
      layout = page.evaluate_script(LAYOUT_PROBE_JS)

      assert_equal "none", layout["paneDisplay"], "the activity pane starts open on a phone"
      assert_equal layout["clientWidth"], layout["main"]["width"],
                   "the matrix does not get the full viewport width"

      assert_equal 0, layout["capabilityColumn"]["left"]
      assert_operator layout["capabilityColumn"]["right"], :<, layout["clientWidth"],
                      "the capability column alone fills the viewport"
      assert_operator layout["firstLevelColumn"]["left"], :<, layout["clientWidth"],
                      "no level column is visible beside the capability column"
    end

    should "open the activity pane as an overlay and close it on an outside tap" do
      toggle_context_pane

      layout = page.evaluate_script(LAYOUT_PROBE_JS)
      assert_equal "fixed", layout["panePosition"], "the pane is not an overlay on a phone"
      assert_equal layout["clientWidth"], layout["pane"]["right"],
                   "the overlay is not anchored to the right edge"
      assert_operator layout["pane"]["left"], :>, 0,
                      "the overlay covers the whole viewport — nothing left to tap outside"
      assert_text "All framework activity"

      # A window capture-phase click-outside listener needs a real MouseEvent —
      # Selenium's synthetic pointer click does not reliably reach it.
      dispatch_click("[data-matrix-target='scrollContainer']")

      assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
    end

    # The strip of grid left beside the overlay is the dismissal target — and
    # it is also the matrix, whose rows expand on click. The tap that closes
    # the pane must not also act on what it landed on.
    should "not act on the grid with the tap that dismisses the overlay" do
      toggle_context_pane
      assert_text "All framework activity"

      dispatch_click("tr[data-matrix-target='row']")

      assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
      assert_no_selector "tr[data-matrix-target='expandedRow']", visible: true
    end

    # Both overlays are z-30 fixed panels: a second one opened over the first
    # buries it — invisible, still "open", and still what Esc closes first.
    should "keep the two overlays mutually exclusive" do
      toggle_role_pane
      assert_selector "[data-framework-explorer-target='rolePane']", visible: true

      toggle_context_pane

      assert_selector "[data-framework-explorer-target='contextPane']", visible: true
      assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true
    end

    should "close the overlay with Esc" do
      toggle_context_pane
      assert_text "All framework activity"

      press_escape

      assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
    end

    should "keep the pane's own close button working" do
      toggle_context_pane
      assert_text "All framework activity"

      # Icon-only (aria-label), and a Capybara click on a Stimulus-action
      # element is the documented drop risk — dispatch it.
      dispatch_click("[aria-label='Close activity feed']")

      assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
    end

    should "move focus into the overlay and hand it back to the toggle" do
      toggle_context_pane
      assert_text "All framework activity"
      assert page.evaluate_script(
        "document.querySelector(\"[data-framework-explorer-target='contextPane']\")" \
        ".contains(document.activeElement)"
      ), "focus stayed on the grid the overlay is covering"

      press_escape

      assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
      assert_equal "contextPaneToggle", page.evaluate_script(
        "document.activeElement.dataset.frameworkExplorerTarget"
      )
    end

    # A tall chrome (200% zoom, a very small window) must not be able to leave
    # the grid with no height at all — the page scrolls instead.
    should "keep the grid a usable height even if the chrome claims the viewport" do
      page.execute_script(<<~JS)
        document.querySelector("[data-controller~='framework-explorer']")
          .style.setProperty("--explorer-offset", "5000px");
      JS

      height = page.evaluate_script(
        "Math.round(document.querySelector(\"[data-framework-explorer-target='layout']\")" \
        ".getBoundingClientRect().height)"
      )
      # The floor is deliberately low (12rem) — it only has to stop the calc
      # collapsing to zero, never to second-guess a layout the measurement can
      # size on its own. The page scrolls to reach the rest.
      assert_operator height, :>=, 192, "the explorer collapsed to nothing"
    end

    # The phone is a REVIEW surface: reading the feed and acting on it is the
    # whole point of the pane being reachable at all.
    should "review a pending clarification from the overlay" do
      ActsAsTenant.with_tenant(@tenant) do
        author = FactoryBot.create(:person, tenant: @tenant, name: "Quinn Questioner")
        Frameworks::CommandHandler.new.request_clarification(
          @framework_id, SecureRandom.uuid_v7, "capability", @cap_id,
          author_id: author.id.to_s, rationale: "Is this one capability or two?"
        )
      end
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      toggle_context_pane
      assert_text "Is this one capability or two?"

      click_button_with_js_fallback "Resolve…", expect_text: "Resolve clarification"
      assert_selector "#resolve-clarification-modal", visible: true

      # Every modal is mounted on the explorer ROOT, so a tap inside the dialog
      # is "outside the pane" — the pane must stand down while one is open, or
      # the reviewer's feed closes behind the dialog they opened from it.
      dispatch_click("#resolve-clarification-modal [data-modal-target='panel']")
      assert_selector "[data-framework-explorer-target='contextPane']", visible: true
      # The dialog itself has to fit the phone, not just open on it.
      modal = page.evaluate_script(<<~JS)
        (() => {
          const r = document.querySelector("#resolve-clarification-modal [data-modal-target='panel']")
            .getBoundingClientRect();
          return { left: Math.round(r.left), right: Math.round(r.right),
                   vw: document.documentElement.clientWidth };
        })()
      JS
      assert_operator modal["left"], :>=, 0
      assert_operator modal["right"], :<=, modal["vw"]
    end
  end

  context "edit mode at 1400x1400" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
      wait_for_stimulus "framework-explorer"
    end

    should "keep the activity pane an inline column, open by default" do
      layout = page.evaluate_script(LAYOUT_PROBE_JS)

      assert_equal "flex", layout["paneDisplay"], "the pane is not open on desktop"
      assert_equal "static", layout["panePosition"], "the pane became an overlay on desktop"
      assert_equal layout["clientWidth"], layout["scrollWidth"]
      # Three columns side by side: role tree, matrix, pane.
      assert_operator layout["main"]["left"], :>, 0, "the role tree is not inline"
      assert_in_delta layout["main"]["right"], layout["pane"]["left"], 1
    end

    should "still close the pane from the Activity toggle" do
      assert_selector "[data-framework-explorer-target='contextPane']", visible: true

      dispatch_click("[data-framework-explorer-target='contextPaneToggle']")

      assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
    end
  end

  private

  # A JS-dispatched `MouseEvent` on a selector: reaches window capture-phase
  # click-outside listeners (which Selenium's synthetic pointer click does not
  # reliably do) and can't be dropped by a starved event loop.
  def dispatch_click(selector)
    dispatched = page.evaluate_script(<<~JS, selector)
      (() => {
        const el = document.querySelector(arguments[0]);
        if (!el) return false;
        el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
        return true;
      })()
    JS
    assert dispatched, "note: JS recovery \u2014 no element matched #{selector.inspect}"
  end
end
