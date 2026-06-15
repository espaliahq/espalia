# frozen_string_literal: true

require "application_system_test_case"

# Smoke tests for Phase 2 — the edit-mode UI affordances.
# Confirms /edit differs from /show in the ways the user can see:
# mode badge in the header, mode switcher, context pane open by default,
# inline-editor controllers + add-illustration frames visible only in edit.
class Frameworks::EditModeSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @viewer_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @viewer_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks clarifying questions")
      handler.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                    eid, rid, 1, "Seeks guidance from tech lead")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "view mode (/frameworks/:id) as admin" do
    should "not show the Edit mode badge" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_no_text "Edit mode", exact: true
    end

    should "show the mode switcher link to edit mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_selector "a[href*='/edit']", text: "Edit mode"
    end

    should "not render the context pane or its toggle at all" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_no_selector "[data-framework-explorer-target='contextPane']"
      assert_no_selector "[data-framework-explorer-target='contextPaneToggle']"
      assert_no_text(/Suggestion/)
    end

    should "not render inline-editor controllers on illustrations" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"
      assert_no_selector "li[data-controller='inline-editor']"
    end

    should "not render the add-illustration frame" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_no_selector "turbo-frame[id^='new-illustration-']"
    end
  end

  context "edit mode (/frameworks/:id/edit) as admin" do
    should "show the Edit mode badge" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
    end

    should "show the mode switcher link back to view mode" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_selector "a", text: "Exit edit mode"
    end

    should "open the context pane by default" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_selector "[data-framework-explorer-target='contextPane']:not(.hidden)"
    end

    should "render inline-editor controllers on illustrations" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "li[data-controller='inline-editor']"
    end

    should "render the add-illustration frame" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "turbo-frame[id^='new-illustration-']"
    end
  end

  context "viewer trying to access /edit" do
    should "be redirected with unauthorized flash" do
      sign_in_as(@viewer_user)
      visit edit_framework_path(@framework_id)
      assert_no_current_path edit_framework_path(@framework_id)
      assert_text(/not authorized/i)
    end
  end

  context "inline editing in edit mode" do
    should "submit a capability name edit and swap the frame" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      # Reveal the inline-editor form for the capability name. The pencil is
      # hover-only in CSS; flip the display/form visibility directly.
      editor = find("turbo-frame#capability-name-" \
                    "#{FrameworkState::Capability.first.capability_id} > div")
      page.execute_script(
        "arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')",
        editor
      )
      page.execute_script(
        "arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')",
        editor
      )

      # Set the value via JS and fire input/change events — Selenium's
      # send_keys can drop characters on starved CI runners, leaving the
      # textarea with the original capability name. The server then sees
      # no-op edit and the assertion below fails. JS assignment is
      # deterministic; the events fire any Stimulus listeners that may
      # gate the submit on dirty-state.
      page.execute_script(<<~JS, editor)
        const ta = arguments[0].querySelector("textarea[name='capability[name]']");
        ta.value = "Sharper Strategic Thinking";
        ta.dispatchEvent(new Event("input", { bubbles: true }));
        ta.dispatchEvent(new Event("change", { bubbles: true }));
      JS
      page.execute_script("arguments[0].querySelector('form').requestSubmit();", editor)

      assert_text "Sharper Strategic Thinking"
      assert_no_text "Strategic Thinking", exact: true
    end

    should "submit a capability description edit and swap the frame" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      cap_id = FrameworkState::Capability.first.capability_id
      editor = find("turbo-frame#capability-description-#{cap_id} > div")
      page.execute_script(
        "arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')",
        editor
      )
      page.execute_script(
        "arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')",
        editor
      )
      page.execute_script(<<~JS, editor)
        const ta = arguments[0].querySelector("textarea[name='capability[description]']");
        ta.value = "Balances competing priorities.";
        ta.dispatchEvent(new Event("input", { bubbles: true }));
        ta.dispatchEvent(new Event("change", { bubbles: true }));
      JS
      page.execute_script("arguments[0].querySelector('form').requestSubmit();", editor)

      assert_text "Balances competing priorities."
    end
  end

  context "Editing / Suggesting toggle" do
    should "render the segmented toggle in edit mode only" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_selector "[data-controller='edit-mode-toggle']"
      assert_selector "button[data-edit-mode-toggle-target='editingButton']", text: "Editing"
      assert_selector "button[data-edit-mode-toggle-target='suggestingButton']", text: "Suggesting"

      visit framework_path(@framework_id)
      assert_no_selector "[data-controller='edit-mode-toggle']"
    end

    should "persist the choice across reload via cookie and land admin edits as pending when Suggesting" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      wait_for_stimulus "edit-mode-toggle"
      # JS-dispatch the click on the suggesting button — Capybara pointer
      # clicks on this toggle have been silently dropped on starved CI,
      # leaving the cookie unset and the reload landing back on Editing.
      page.execute_script(<<~JS)
        document.querySelector("button[data-edit-mode-toggle-target='suggestingButton']")?.click();
      JS

      # Wait for the controller to actually apply Suggesting before reload —
      # the click handler writes the cookie synchronously, but aria-pressed
      # is set inside the same handler, so it's our most reliable sentinel.
      assert_selector(
        "button[data-edit-mode-toggle-target='suggestingButton'][aria-pressed='true']"
      )

      # Reload — the toggle should still show Suggesting as the active segment.
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "edit-mode-toggle"
      assert_equal "true",
        find("button[data-edit-mode-toggle-target='suggestingButton']")["aria-pressed"]
      assert_equal "false",
        find("button[data-edit-mode-toggle-target='editingButton']")["aria-pressed"]

      # Inline-edit a capability name.
      cap_id = FrameworkState::Capability.first.capability_id
      editor = find("turbo-frame#capability-name-#{cap_id} > div")
      page.execute_script(
        "arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')",
        editor
      )
      page.execute_script(
        "arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')",
        editor
      )
      editor.find("textarea[name='capability[name]']").fill_in with: "Proposed Name"
      page.execute_script("arguments[0].querySelector('form').requestSubmit();", editor)

      # Wait for the Turbo frame to swap — pending-edit decoration is the
      # reliable signal that the server responded.
      assert_selector "turbo-frame#capability-name-#{cap_id} .decoration-wavy"

      # Even though the current user is a tenant admin (auto-approve authority),
      # Suggesting mode overrides and the change lands as pending. The
      # grid still shows the old name because no auto-approval ran.
      suggestion = FrameworkState::SuggestedEdit.where(
        framework_id: @framework_id,
        target_entity_type: "capability",
        target_entity_id: cap_id
      ).last
      assert_equal "pending", suggestion.status
      assert_equal "Proposed Name", suggestion.suggested_value

      # The suggestions pane should surface the freshly-landed pending row
      # WITHOUT a page refresh — the inline-editor dispatches
      # `suggestion:submitted` and the context pane reloads its frame.
      within "#suggestion-panel" do
        assert_text "Proposed Name"
      end
    end
  end

  context "filtering in edit mode" do
    # Regression: the matrix Turbo Frame re-fetch on filter used the
    # view-mode `/matrix` endpoint regardless of mode, so applying (or
    # clearing) a role/text filter silently dropped the explorer back to
    # published/view state — losing the inline-editor affordances.
    should "keep the matrix in edit mode after a text filter and after clearing it" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      # The frame re-fetches from the edit-matrix endpoint, never view mode.
      assert_selector "turbo-frame#framework-matrix"
      assert_match %r{/edit/matrix},
        find("[data-controller='matrix']")["data-matrix-base-path-value"]

      # Apply a text filter that matches the capability. Set the value via JS
      # + input/change events — Selenium's send_keys drops characters on
      # starved CI, and the debounced filter assertion below depends on the
      # exact query (see docs/guidelines/testing.md → inline-editor form submits).
      set_search_query "Strategic"
      assert_text "Strategic Thinking"

      # Still edit mode: expanding the row reveals the inline editors that
      # only render in edit mode.
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "li[data-controller='inline-editor']"

      # Clear the filter — must remain in edit mode.
      set_search_query ""
      assert_text "Strategic Thinking"
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "li[data-controller='inline-editor']"
    end
  end

  context "draft status pill" do
    should "not show the draft pill when no draft is open (edit mode)" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
      # Target the draft *pill* (e.g. "v2 draft"), not page-wide text — the
      # activity feed legitimately mentions "Opened draft v1" as a lifecycle
      # entry, which an /draft/i page scan would wrongly catch.
      assert_no_text(/v\d+ draft/i)
    end

    context "with an open draft" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          Frameworks::CommandHandler.new.start_draft(@framework_id, 2, "test")
        end
      end

      should "show the draft pill in edit mode" do
        sign_in_as(@admin_user)
        visit edit_framework_path(@framework_id)
        assert_text "v2 draft"
      end

      should "never reveal the draft in view mode" do
        sign_in_as(@admin_user)
        visit framework_path(@framework_id)
        assert_text "Strategic Thinking"
        assert_no_text(/draft/i)
      end

      should "show the Publish button for an admin and publish via the review page" do
        sign_in_as(@admin_user)
        visit edit_framework_path(@framework_id)
        assert_text "v2 draft"

        # Publish now routes to the review page (no archived caps here), then
        # the owner confirms.
        click_link_with_js_fallback("Publish v2", expect_text: "No capabilities are being retired")
        click_button_with_js_fallback("Confirm & publish v2", expect_text: "Published v2")

        # Draft is published: the flash confirms, the draft pill is gone.
        assert_text "Published v2"
        assert_no_text "v2 draft"
      end
    end
  end

  context "adding structural content" do
    should "not show the add affordances in view mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_no_selector "button[data-modal-target-id='add-category-modal']"
      assert_no_selector "button[data-modal-target-id='add-capability-modal']"
    end

    should "add a category via the modal" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-category-modal']\").click();"
      )
      assert_selector "#add-category-modal", visible: true
      within "#add-category-modal" do
        fill_in "add_category_name", with: "Delivery & Craft"
      end
      click_button_with_js_fallback("Add category", expect_text: "Added category")
      assert_text "Added category"
      # The new (still empty) category must stay visible in edit mode so it can
      # be populated — otherwise its "+ Add capability" affordance vanishes.
      assert_text "Delivery & Craft"
    end

    should "add a capability (with a role) via the modal, prefilled with its category" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-capability-modal']\").click();"
      )
      assert_selector "#add-capability-modal", visible: true
      within "#add-capability-modal" do
        assert_text "Thinking" # category name prefilled from the trigger
        fill_in "add_capability_name", with: "Systems Design"
        check "Software Engineer"
      end
      click_button_with_js_fallback("Add capability", expect_text: "Added")
      assert_text "Added"
    end
  end

  context "archiving a capability via the row kebab" do
    should "not show the kebab in view mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_no_selector "button[aria-label='Capability actions']"
    end

    should "open the archive modal from the kebab and archive with a mapping" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      # Kebab is hover-revealed in the capability name cell; JS-click it to
      # open the shared archive modal (Selenium pointer clicks on the
      # opacity-0 control flake on starved CI).
      assert_selector "button[aria-label='Capability actions']", visible: :all
      page.execute_script(<<~JS)
        document.querySelector("button[aria-label='Capability actions']").click();
      JS

      assert_selector "#archive-capability-modal", visible: true
      within "#archive-capability-modal" do
        assert_text "Strategic Thinking"
        # Retire with no survivor (single-capability fixture).
        select "Archive — retire with no replacement", from: "Migration mapping"
      end

      # Submit via the JS-fallback helper — the modal submit is a navigation
      # click that can be dropped on starved CI.
      click_button_with_js_fallback("Archive capability", expect_text: "Archived")
      assert_text "Archived"
      # Draft auto-opened by the archive; the pill reflects it.
      assert_text(/draft/i)
    end
  end

  context "inline diff for pending text edits" do
    should "render added and removed spans when a small pending edit exists on a capability name" do
      capability = FrameworkState::Capability.first
      FactoryBot.create(:framework_suggested_edit,
        tenant: @tenant,
        framework_id: @framework_id,
        target_entity_type: "capability",
        target_entity_id: capability.capability_id,
        field: "name",
        current_value: capability.name,
        suggested_value: "Strategic Thinkings",
        kind: "edit",
        status: "pending")

      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      within "turbo-frame#capability-name-#{capability.capability_id}" do
        # Added suffix "s" is styled with the sky-blue wavy underline.
        assert_selector "span.decoration-sky-400", text: "s"
        # Amber wavy underline no longer decorates the entity wrapper.
        assert_no_selector "span.decoration-amber-400"
      end
    end

    should "render the proposed value styled as sky-blue when the diff exceeds the density threshold" do
      capability = FrameworkState::Capability.first
      FactoryBot.create(:framework_suggested_edit,
        tenant: @tenant,
        framework_id: @framework_id,
        target_entity_type: "capability",
        target_entity_id: capability.capability_id,
        field: "name",
        current_value: capability.name,
        suggested_value: "Totally Unrelated Replacement Text",
        kind: "edit",
        status: "pending")

      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      within "turbo-frame#capability-name-#{capability.capability_id}" do
        assert_selector "span.decoration-sky-400", text: "Totally Unrelated Replacement Text"
        assert_no_selector "span.line-through"
      end
    end

    should "render the inline diff on an illustration when a pending edit exists" do
      illustration = FrameworkState::RoleIllustration.first
      FactoryBot.create(:framework_suggested_edit,
        tenant: @tenant,
        framework_id: @framework_id,
        target_entity_type: "role_illustration",
        target_entity_id: illustration.illustration_id,
        field: "description",
        current_value: illustration.description,
        suggested_value: "Seeks guidance from tech leads",
        kind: "edit",
        status: "pending")

      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")

      within "turbo-frame#illustration-#{illustration.illustration_id}" do
        # Added "s" at the end renders as a sky-blue wavy span.
        assert_selector "span.decoration-sky-400", text: "s"
      end
    end
  end

  private

  # Sets the framework-explorer capability search box to `query` via a JS
  # value assignment + input/change events. Selenium's send_keys drops
  # characters on starved CI runners, and the debounced filter assertions
  # depend on the exact query landing — JS assignment is deterministic and
  # the dispatched `input` event still drives `framework_search_controller`.
  def set_search_query(query)
    input = find("[data-framework-search-target='input']")
    page.execute_script(<<~JS, input, query)
      const el = arguments[0];
      el.value = arguments[1];
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS
  end
end
