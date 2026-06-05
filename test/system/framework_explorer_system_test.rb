# frozen_string_literal: true

require "application_system_test_case"

class FrameworkExplorerSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")

      # ── Department: Product + Engineering ──
      # Role family: Product Design
      @pd_family_id = SecureRandom.uuid_v7
      @pd_role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, @pd_family_id, "Product Design")
      handler.add_role(@framework_id, @pd_role_id, @pd_family_id, "Product Designer", "PD", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @pd_role_id, 1, "Associate Product Designer", "PD1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @pd_role_id, 2, "Product Designer", "PD2")

      # Role family: Software Engineering
      @eng_family_id = SecureRandom.uuid_v7
      @eng_role_id = SecureRandom.uuid_v7
      @em_role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, @eng_family_id, "Software Engineering")
      handler.add_role(@framework_id, @eng_role_id, @eng_family_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @eng_role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @eng_role_id, 2, "Engineer II", "E2")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @eng_role_id, 3, "Senior Engineer", "E3")
      handler.add_role(@framework_id, @em_role_id, @eng_family_id, "Engineering Manager", "EM", "management")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @em_role_id, 3, "Engineering Manager", "EM3")

      # ── Department: Finance ──
      # Role family: Financial Control
      @fc_family_id = SecureRandom.uuid_v7
      @fc_role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, @fc_family_id, "Financial Control")
      handler.add_role(@framework_id, @fc_role_id, @fc_family_id, "Financial Controller", "FC", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @fc_role_id, 1, "Junior Financial Controller", "FC1", is_entry: true)

      # ── Capability: bound to PD and E roles ──
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @pd_role_id)
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @eng_role_id)
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @em_role_id)

      # Expectation at level 1 with illustrations for PD and E
      eid = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks clarifying questions")
      handler.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, eid, @pd_role_id, 1, "Runs user research sessions")
      handler.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, eid, @eng_role_id, 1, "Reviews technical requirements")

      # Expectation at level 2
      eid2 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, eid2, SecureRandom.uuid_v7, cap_id, 2, "Identifies root causes")

      # Publish v1 so shape-changing events land in the read model.
      # Note: rebuild wipes child read models and replays events, so direct
      # read-model-only updates (department) must happen AFTER publish.
      handler.publish_version(@framework_id, "test")

      # Department is a read-model-only field (not event-sourced) — set after publish
      FrameworkState::RoleFamily.find_by!(role_family_id: @pd_family_id).update!(department: "Product + Engineering")
      FrameworkState::RoleFamily.find_by!(role_family_id: @eng_family_id).update!(department: "Product + Engineering")
      FrameworkState::RoleFamily.find_by!(role_family_id: @fc_family_id).update!(department: "Finance")
    end

    sign_in_as(@user)
  end

  context "role filtering in columns and illustrations" do
    should "only show selected role level titles in column headers when visiting with role param" do
      # Visit with only Product Designer selected
      visit framework_path(@framework_id, roles: [ @pd_role_id ])

      # Should see PD level titles (full titles shown when few roles selected)
      assert_text "Associate Product Designer"

      # Should NOT see Engineering level titles
      assert_no_text "Engineer I"
      assert_no_text "Engineer II"
      assert_no_text "Senior Engineer"
    end

    should "only show selected role illustrations in expanded cells" do
      # Visit with only Product Designer selected
      visit framework_path(@framework_id, roles: [ @pd_role_id ])

      # Expand the single capability row via the CI-resilient toggle helper.
      # A bare find(...).click was silently dropped on slow CI runners when
      # Chrome's JS event loop was starved; the helper retries once if the
      # click was lost and asserts the expanded row becomes visible.
      expand_matrix_row("tr[data-matrix-target='row']")

      # Should see PD illustration
      assert_text "Runs user research sessions"

      # Should NOT see Engineering illustration
      assert_no_text "Reviews technical requirements"
    end

    should "update matrix columns when unchecking roles via checkbox" do
      # Visit with all roles (default)
      visit framework_path(@framework_id)

      # Initially all level codes visible (many roles = compact codes)
      assert_text "E1"
      assert_text "PD1"

      # Uncheck E, EM, FC via JS + change events (styled checkboxes need JS toggling)
      [ @eng_role_id, @em_role_id, @fc_role_id ].each do |role_id|
        page.execute_script(
          "var cb = document.querySelector('input[data-role-id=\"#{role_id}\"]'); " \
          "cb.checked = false; cb.dispatchEvent(new Event('change', { bubbles: true }));"
        )
      end

      # Wait for Turbo Frame to update — PD should now be the only role
      # With only 1 role, headers switch to full titles
      assert_text "Associate Product Designer"
      assert_no_text "E1"
      assert_no_text "FC1"
    end
  end

  context "column header titles" do
    should "show full level titles in column headers when few roles selected" do
      # Visit with only Product Designer selected
      visit framework_path(@framework_id, roles: [ @pd_role_id ])

      # Should show full level titles (not just codes) since only 1 role
      assert_text "Associate Product Designer"
      assert_text "Product Designer" # level title
    end
  end

  context "department hierarchy in role tree" do
    should "show departments grouping role families" do
      visit framework_path(@framework_id)

      within "[data-framework-explorer-target='rolePane']" do
        # Should see department groupings (rendered uppercase via CSS)
        assert_selector "div", text: /finance/i
        assert_selector "div", text: /product \+ engineering/i

        # Should see role families nested under departments
        assert_text "Product Design"
        assert_text "Software Engineering"
        assert_text "Financial Control"
      end
    end
  end

  context "clear all roles" do
    should "uncheck every role, then let you build a fresh selection" do
      visit framework_path(@framework_id)

      # Default load selects every role (empty selection = filter cleared)
      assert_text "E1"
      assert_text "PD1"

      # JS-dispatch the click — a Capybara pointer click on a Stimulus-action
      # button can be silently dropped on a starved CI runner. Re-dispatch once
      # if the action hadn't attached yet; clearAll is idempotent.
      # See docs/guidelines/testing.md.
      clear_all = "document.querySelector(\"[data-action='tree#clearAll']\")?.click()"
      page.execute_script(clear_all)
      if page.has_css?("input[data-role-id='#{@pd_role_id}']:checked", visible: :all, wait: 3)
        page.execute_script(clear_all)
      end

      assert_no_selector "input[data-role-id='#{@pd_role_id}']:checked", visible: :all

      every_role_unchecked =
        "Array.from(document.querySelectorAll(\"input[type=checkbox][data-role-id]\"))" \
        ".every(function (cb) { return !cb.checked })"
      assert page.evaluate_script(every_role_unchecked),
        "Expected every role checkbox to be unchecked after Clear All"

      # Tick a single role to build a fresh selection — matrix narrows to it
      page.execute_script(
        "var cb = document.querySelector('input[data-role-id=\"#{@pd_role_id}\"]'); " \
        "cb.checked = true; cb.dispatchEvent(new Event('change', { bubbles: true }));"
      )

      assert_text "Associate Product Designer"
      assert_no_text "E1"
      assert_no_text "FC1"
    end
  end

  context "solo discovery hint" do
    should "surface the solo tip and remember dismissal across reloads" do
      visit framework_path(@framework_id)

      assert_selector "[data-tree-target='hint']", text: /Solo/i

      # JS-dispatch the dismiss click (Stimulus-action element — a pointer
      # click can be dropped on starved CI). Re-dispatch once if the hint
      # survives; the click is idempotent. See docs/guidelines/testing.md.
      dismiss = "document.querySelector(\"[data-action='tree#dismissHint']\")?.click()"
      page.execute_script(dismiss)
      page.execute_script(dismiss) if page.has_selector?("[data-tree-target='hint']", wait: 3)

      assert_no_selector "[data-tree-target='hint']"

      # Reload — dismissal persists via localStorage, so the tip stays gone
      visit framework_path(@framework_id)
      assert_no_selector "[data-tree-target='hint']"
    end
  end

  context "sticky header on vertical scroll" do
    should "keep column headers pinned to the top of the scroll container" do
      # Short viewport forces the matrix to overflow vertically even with one
      # capability row — expanding it adds illustration rows so there is
      # definitely something to scroll past.
      page.driver.browser.manage.window.resize_to(1400, 500)
      visit framework_path(@framework_id, roles: [ @pd_role_id ])

      expand_matrix_row("tr[data-matrix-target='row']")

      # The table must be a direct child of the turbo-frame inside the scroll
      # container — an intermediate overflow wrapper would capture the sticky
      # anchor and break vertical stickiness (see framework-explorer.md §11).
      assert_selector "[data-matrix-target='scrollContainer'] > turbo-frame#framework-matrix > table"

      scrolled = page.evaluate_script(<<~JS)
        (() => {
          const pane = document.querySelector('[data-matrix-target="scrollContainer"]');
          pane.scrollTop = 300;
          return pane.scrollTop;
        })()
      JS
      assert scrolled.positive?, "Expected matrix pane to scroll vertically (got scrollTop=#{scrolled})"

      header_pinned = page.evaluate_script(<<~JS)
        (() => {
          const pane = document.querySelector('[data-matrix-target="scrollContainer"]');
          const corner = pane.querySelector('thead th');
          const paneRect = pane.getBoundingClientRect();
          const cornerRect = corner.getBoundingClientRect();
          return Math.abs(cornerRect.top - paneRect.top) < 2;
        })()
      JS
      assert header_pinned, "Column header should stay pinned to the top of the scroll container after scrolling"
    end
  end

  context "responsive behaviour" do
    should "show role tree inline on desktop and toggle it" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit framework_path(@framework_id)

      assert_selector "[data-framework-explorer-target='rolePane']", visible: true
      # Wait for Stimulus to connect — connect() applies text-primary to the toggle button
      wait_for_stimulus "framework-explorer"

      # Click the toggle to hide — target the action attribute (the canonical
      # selector used by toggle_role_pane) rather than button text. A text
      # match risked finding a similarly-labelled button inside the role
      # pane content. JS-dispatched click bypasses Selenium pointer
      # hit-testing entirely.
      hide_role_pane_js = <<~JS
        document.querySelector("[data-action*='framework-explorer#toggleRolePane']")?.click();
      JS
      page.execute_script(hide_role_pane_js)

      unless page.has_no_css?(
        "[data-framework-explorer-target='rolePane']", visible: true, wait: 4
      )
        page.execute_script(hide_role_pane_js)
      end

      assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true

      # Click to show again
      toggle_role_pane
    end

    should "hide role tree on mobile and show it via toggle button" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit framework_path(@framework_id)

      # Wait for Stimulus to connect before interacting
      assert_selector "[data-controller='framework-explorer'][data-connected]"

      # Role pane should be hidden on mobile
      assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true

      # Toggle button should be visible
      assert_selector "button", text: "Roles", visible: true

      # Click toggle to show role tree
      toggle_role_pane
      assert_text "Product Design"
      assert_text "Software Engineering"
    end

    should "close mobile role tree overlay when clicking outside" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit framework_path(@framework_id)

      # Wait for Stimulus to connect before interacting
      assert_selector "[data-controller='framework-explorer'][data-connected]"

      # Open the role pane
      toggle_role_pane

      # Click outside the role pane (right side of viewport, past the 18rem overlay).
      # Uses JS dispatch because Selenium's synthetic pointer events at viewport
      # coordinates don't reliably trigger window capture-phase listeners
      # (used by stimulus-use's useClickOutside) in headless Chrome.
      page.execute_script(
        "document.elementFromPoint(350, 400)" \
        ".dispatchEvent(new MouseEvent('click', " \
        "{bubbles: true, cancelable: true, clientX: 350, clientY: 400, view: window}))"
      )

      # Role pane should close
      assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true
    end
  end
end
