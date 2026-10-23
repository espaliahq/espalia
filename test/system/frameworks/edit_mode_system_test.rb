# frozen_string_literal: true

require "application_system_test_case"

# Smoke tests for Phase 2 — the edit-mode UI affordances.
# Confirms /edit differs from /show in the ways the user can see:
# mode badge in the header, mode switcher, context pane open by default,
# inline-edit hosts + add-illustration frames visible only in edit.
class Frameworks::EditModeSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @viewer_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @viewer_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @rfid = rfid = SecureRandom.uuid_v7
      @rid = rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @cap_id = cap_id = SecureRandom.uuid_v7
      @eid = eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks clarifying questions")
      handler.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7,
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

    should "not render inline-edit hosts on illustrations" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"
      assert_no_selector "li[data-editor-action]"
    end

    should "not render the shared inline-editor template or its controller" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_no_selector "[data-controller~='field-editor']", visible: :all
      assert_no_selector "[data-field-editor-target='template']", visible: :all
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

    should "render inline-edit hosts on illustrations" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "li[data-editor-action]"
    end

    should "ship ONE shared editor template and no pre-rendered inline-edit forms" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_selector "[data-controller~='field-editor'][data-connected]", visible: :all
      assert_selector "[data-field-editor-target='template']", count: 1, visible: :all
      # The matrix ships display markup + data only — the editor is cloned in
      # on demand (#379). Only the template's own textarea exists, and it is
      # inert inside <template>, so nothing matches in the live DOM.
      assert_no_selector "#framework-matrix textarea", visible: :all
      assert_no_selector "#framework-matrix [data-editor-form]", visible: :all
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

      editor = find("turbo-frame#capability-name-" \
                    "#{FrameworkState::Capability.first.capability_id} > div")
      form = start_inline_edit(editor)
      submit_inline_edit(form, with: "Sharper Strategic Thinking")

      assert_text "Sharper Strategic Thinking"
      assert_no_text "Strategic Thinking", exact: true
    end

    should "submit a capability description edit and swap the frame" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      cap_id = FrameworkState::Capability.first.capability_id
      editor = find("turbo-frame#capability-description-#{cap_id} > div")
      form = start_inline_edit(editor)
      submit_inline_edit(form, with: "Balances competing priorities.")

      assert_text "Balances competing priorities."
    end

    should "keep the category-name inline editor intact inside the focus target" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      cat_id = FrameworkState::CapabilityCategory.first.category_id
      editor = find("turbo-frame#category-name-#{cat_id} > div")
      # Regression: the focus target wrapping the name must be a role=button
      # span, not a <button> — a <button> ancestor makes the browser reparent
      # the nested pencil out, breaking name editing. Assert the editor host +
      # pencil survive inside the focus target.
      assert_equal "/frameworks/#{@framework_id}/categories/#{cat_id}", editor[:"data-editor-action"]
      assert editor.has_css?("[data-action*='field-editor#open']", visible: :all)

      form = start_inline_edit(editor)
      submit_inline_edit(form, with: "Cognition & Judgement")

      assert_text "Cognition & Judgement"
    end

    should "submit a category description edit and swap the frame" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      cat_id = FrameworkState::CapabilityCategory.first.category_id
      editor = find("turbo-frame#category-description-#{cat_id} > div")
      form = start_inline_edit(editor)
      submit_inline_edit(form, with: "How we reason and decide.")

      assert_text "How we reason and decide."
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
      form = start_inline_edit(editor)
      # The Save button states what will actually happen: Suggesting mode means
      # this lands as a proposal even for an auto-approve authority holder.
      assert_equal "Propose", form.find("[data-editor-submit]").text
      submit_inline_edit(form, with: "Proposed Name")

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
      # WITHOUT a page refresh — the shared editor dispatches
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
      # The filter triggers a debounced Turbo Frame fetch; wait for content
      # that only the FILTERED render carries (the results banner) before
      # the frame-complete check — `[complete]` alone can match the
      # previous load if the debounce hasn't fired yet, letting
      # expand_matrix_row click an old row whose replacement then collapses
      # the expanded content mid-assertion.
      assert_text "capabilities matching"
      assert_selector "turbo-frame#framework-matrix[complete]", visible: :all
      wait_for_stimulus "matrix"

      # Still edit mode: expanding the row reveals the inline editors that
      # only render in edit mode.
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "li[data-editor-action]"

      # Clear the filter — must remain in edit mode. Sync on the banner
      # DISAPPEARING (only true of the cleared render) for the same
      # debounce race as above.
      set_search_query ""
      assert_no_text "capabilities matching"
      assert_text "Strategic Thinking"
      assert_selector "turbo-frame#framework-matrix[complete]", visible: :all
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "li[data-editor-action]"
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

        # Publish routes to the review page (no archived caps here), then the
        # owner confirms. The publish itself runs in a background job, so the
        # header immediately shows the disabled "Publishing" state instead of
        # a second Publish button.
        click_link_with_js_fallback("Publish v2", expect_text: "What changes in v2")
        click_button_with_js_fallback("Confirm & publish v2", expect_text: "Publishing v2 in the background")
        assert_text "v2 draft"
        assert_button "Publishing v2…", disabled: true
        assert_no_link "Publish v2"

        # Once the job has run, a reload shows the draft gone.
        perform_enqueued_jobs(only: Frameworks::PublishVersionJob)
        visit edit_framework_path(@framework_id)
        assert_no_text "v2 draft"
        assert_no_button "Publishing v2…"
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
        js_fill_in "add_category_name", with: "Delivery & Craft"
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
        js_fill_in "add_capability_name", with: "Systems Design"
        check "Software Engineer"
      end
      # "Added" is all over the activity feed — the new capability landing in
      # the matrix is the signal. Scoped to the modal: the grid's own
      # "Add capability" ghost carries the same label (#380).
      click_selector_with_js_fallback(
        "#add-capability-modal button[type='submit']", expect_text: "Systems Design"
      )
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

      # Kebab is a hover-revealed dropdown in the capability name cell; JS-click
      # the trigger to open the menu, then the "Archive…" item to open the shared
      # archive modal (Selenium pointer clicks on the opacity-0 control flake on
      # starved CI).
      assert_selector "button[aria-label='Capability actions']", visible: :all
      page.execute_script(<<~JS)
        document.querySelector("button[aria-label='Capability actions']").click();
      JS
      assert_text "Archive…"
      page.execute_script(<<~JS)
        [...document.querySelectorAll("[role='menuitem']")]
          .find((b) => b.textContent.trim().startsWith("Archive")).click();
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

  context "strikethrough for a capability staged for archive" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @struck_cap = FrameworkState::Capability.first.capability_id
        Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
          Frameworks::CommandHandler.new.archive_capability(@framework_id, @struck_cap, reason: "going away")
        end
      end
    end

    should "strike the row through in edit mode" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_selector "tr[data-capability-id='#{@struck_cap}']"
      assert_text "Pending archive"
      decoration = page.evaluate_script(
        "getComputedStyle(document.querySelector(\"tr[data-capability-id='#{@struck_cap}'] > td\")).textDecorationLine"
      )
      assert_equal "line-through", decoration
    end

    should "not strike the row in view mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_selector "tr[data-capability-id='#{@struck_cap}']"
      decoration = page.evaluate_script(
        "getComputedStyle(document.querySelector(\"tr[data-capability-id='#{@struck_cap}'] > td\")).textDecorationLine"
      )
      assert_equal "none", decoration
    end
  end

  context "archiving a category via the header kebab" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @empty_cat = SecureRandom.uuid_v7
        # Shape-preserving add — applies live, no draft needed; an empty
        # category is the archivable case (the aggregate refuses a non-empty one).
        Frameworks::CommandHandler.new.add_capability_category(
          @framework_id, @empty_cat, "Retire Me", ordinal: 2
        )
      end
    end

    should "only offer the archive kebab on the empty category, not the populated one" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      assert_text "Retire Me"
      # Every category header carries a kebab, but only the empty one's menu
      # offers Archive — the flag the client-side builder gates on.
      assert_selector "button[data-menu='category'][data-menu-archive]", count: 1, visible: :all
      open_explorer_menu("Category actions", scope: "tr[data-category-id='#{@empty_cat}']")
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Archive…"
    end

    should "open the archive-category modal from the kebab and archive the empty category" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_text "Retire Me"

      use_explorer_menu("Category actions", "Archive…",
                        scope: "tr[data-category-id='#{@empty_cat}']")
      assert_selector "#archive-category-modal", visible: true
      within "#archive-category-modal" do
        assert_text "Retire Me" # name prefilled from the trigger dataset
      end

      click_button_with_js_fallback("Archive category", expect_text: "Archived")
      assert_text "Archived"
      # Archiving is shape-changing — a draft auto-opens.
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
        assert_selector "span.decoration-suggestion-add", text: "s"
        # Amber wavy underline no longer decorates the entity wrapper.
        assert_no_selector "span.decoration-suggestion-edit"
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
        assert_selector "span.decoration-suggestion-add", text: "Totally Unrelated Replacement Text"
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
        assert_selector "span.decoration-suggestion-add", text: "s"
      end
    end

    should "render the inline diff on a capability description on full render" do
      capability = FrameworkState::Capability.first
      FactoryBot.create(:framework_suggested_edit,
        tenant: @tenant,
        framework_id: @framework_id,
        target_entity_type: "capability",
        target_entity_id: capability.capability_id,
        field: "description",
        current_value: capability.description.to_s,
        suggested_value: "Considers long-term impact",
        kind: "edit",
        status: "pending")

      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      # The suggested description must decorate on a full matrix render — not
      # only on the controller re-render right after submitting.
      within "turbo-frame#capability-description-#{capability.capability_id}" do
        assert_selector "span.decoration-suggestion-add", text: "Considers long-term impact"
        # The editor is seeded with the pending PROPOSAL (so editing refines it),
        # not the original value — the host carries it for the shared editor.
        assert_equal "Considers long-term impact",
                     find("[data-editor-action]", visible: :all)[:"data-editor-value"]
      end
    end
  end

  context "adding org structure via the tree" do
    should "not show the add affordances in view mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text "Test Framework"
      assert_no_selector "button[data-modal-target-id='role-family-new-modal']"
      assert_no_selector "button[data-modal-target-id='add-role-modal']"
      assert_no_selector "button[data-modal-target-id='add-level-modal']"
    end

    should "add a role family via the tree-foot modal" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='role-family-new-modal']\").click();"
      )
      assert_selector "#role-family-new-modal", visible: true
      # Assertion-critical values — JS-set + dispatch instead of send_keys,
      # which drops characters on starved CI.
      js_set_field "#role-family-new-modal-name", "Design"
      js_set_field "#role-family-new-modal-department", "Product + Design"
      click_button_with_js_fallback("Add role family", expect_text: "No roles yet")

      within "[data-controller~='tree']" do
        # New family lands under its department header (rendered uppercase via
        # CSS text-transform — assertions must match the rendered case).
        assert_text "PRODUCT + DESIGN"
        assert_selector "span.decoration-wavy", text: "Design"
        assert_text "No roles yet"
      end
      assert_no_selector "#role-family-new-modal", visible: true
    end

    should "add a role via a family's add-role row, parent implied by placement" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-role-modal']\").click();"
      )
      assert_selector "#add-role-modal", visible: true
      within "#add-role-modal" do
        assert_text "In Engineering" # family prefilled from the trigger
        select "Management", from: "add-role-modal-track"
      end
      # Assertion-critical values — JS-set + dispatch instead of send_keys.
      js_set_field "#add-role-modal-name", "Engineering Manager"
      js_set_field "#add-role-modal-code", "EM"
      click_button_with_js_fallback("Add role", expect_text: "Engineering Manager")

      within "[data-controller~='tree']" do
        # New role appears under its family as a ghost (no published levels).
        assert_selector "span.decoration-wavy[title*='Not in the published framework']",
                        text: "Engineering Manager"
      end
      assert_no_selector "#add-role-modal", visible: true
    end
  end

  context "adding a level via the role row" do
    should "prefill the next ordinal, join a draft, and render the new column" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-level-modal']\").click();"
      )
      assert_selector "#add-level-modal", visible: true
      within "#add-level-modal" do
        assert_text "For Software Engineer" # role prefilled from the trigger
        # Next free ordinal — the seeded role has L1.
        assert_equal "2", find("#add-level-ordinal").value
        assert_text "joins the draft"
      end
      js_set_field "#add-level-title", "Engineer II"
      js_set_field "#add-level-code", "E2"
      click_button_with_js_fallback("Add level", expect_text: "Added level")

      # Shape-changing: the draft opened (auto), and the edit-mode matrix
      # renders the new draft column immediately — its title wiggled (the
      # differs-from-published signal) in the header.
      assert_text "v2 draft"
      assert_text "Level 2"
      within "thead" do
        assert_selector "span.decoration-wavy", text: "Engineer II"
      end
    end

    should "replace the header title with the inline editor, not render beside it" do
      ActsAsTenant.with_tenant(@tenant) do
        # A second level so the full-title header has content to edit at L2.
        handler = Frameworks::CommandHandler.new
        handler.add_level(@framework_id, SecureRandom.uuid_v7, @rid, 2, "Engineer II", "E2")
      end

      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      frame = find("turbo-frame[id^='level-title-']", match: :first)
      start_inline_edit(frame)

      within frame do
        assert_selector "[data-editor-form]", visible: true
        # The display element must actually hide — a `hidden` class loses to a
        # competing `inline-flex` on the same element (assessments.md
        # Lesson 17), which left the editor rendering BESIDE the title, so the
        # editor sets display:none inline instead.
        assert_no_selector "[data-editor-display]", visible: true
      end
    end

    should "block a duplicate ordinal inline, in the modal, without a round-trip" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-level-modal']\").click();"
      )
      assert_selector "#add-level-modal", visible: true

      # The seeded role already has L1 — typing it shows the error immediately.
      js_set_field "#add-level-ordinal", "1"
      assert_text "This role already has a level 1"

      js_set_field "#add-level-title", "Dup"
      js_set_field "#add-level-code", "D1"
      page.execute_script(
        "document.querySelector('#add-level-modal form').requestSubmit();"
      )

      # Submit blocked client-side: modal stays open, no draft opened.
      assert_selector "#add-level-modal", visible: true
      assert_no_text "v2 draft"

      # Correcting the ordinal clears the error.
      js_set_field "#add-level-ordinal", "2"
      assert_no_text "This role already has a level 1"
    end

    # The "+ level" trigger lives in the role pane, an overlay on narrow
    # viewports — reachable once toggled open (mirrors the role-family dialog's
    # narrow-viewport test; the modal itself is viewport-independent).
    should "reach the add-level modal on a narrow viewport via the role pane overlay" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      toggle_role_pane

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-level-modal']\").click();"
      )
      assert_selector "#add-level-modal", visible: true
      within "#add-level-modal" do
        assert_text "For Software Engineer"
        assert_equal "2", find("#add-level-ordinal").value
      end
    end
  end

  context "org-structure field editors" do
    should "edit a role's code and track via the kebab dialog" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      # The kebab menu item carries the prefill dataset; JS-click it directly
      # (hover-revealed trigger + menu — pointer clicks flake on CI).
      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='role-edit-modal']\").click();"
      )
      assert_selector "#role-edit-modal", visible: true
      within "#role-edit-modal" do
        assert_equal "Software Engineer", find("#role-edit-modal-name").value
        assert_equal "E", find("#role-edit-modal-code").value
        assert_equal "ic", find("#role-edit-modal-track").value
        select "Management", from: "role-edit-modal-track"
      end
      js_set_field "#role-edit-modal-code", "SWE"
      # Success signal: the modal (its visible "Edit role" title) goes away.
      click_button_with_js_fallback("Save", expect_no_text: "Edit role")

      # Tree frame re-rendered with the updated trigger dataset (kebab items
      # are hidden until the menu opens — assert on the DOM, not visibility).
      assert_selector "button[data-role-edit-code='SWE']", visible: :all
      assert_selector "button[data-role-edit-track='management']", visible: :all
      assert_no_selector "#role-edit-modal", visible: true
    end

    should "manage levels via the editor: row save, entry flag, add, duplicate error" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='level-editor-modal']\").click();"
      )
      assert_selector "#level-editor-modal", visible: true
      within "#level-editor-modal" do
        assert_text "Levels of Software Engineer"
        assert_selector "input[name='level[title]'][value='Engineer I']"

        # Row save: change the code.
        row = find("li", text: "L1")
        js_set_field "#level-editor li input[name='level[code]']", "ENG1"
        page.execute_script("arguments[0].querySelector('form').requestSubmit();", row)
        assert_selector "input[name='level[code]'][value='ENG1']"

        # Entry flag: set L1 as entry — badge appears.
        assert_no_text "Entry", exact: true
        page.execute_script(<<~JS)
          const row = [...document.querySelectorAll('#level-editor-modal li')].find(li => li.textContent.includes('L1'));
          [...row.querySelectorAll('form')].at(-1).requestSubmit();
        JS
        assert_selector "span", text: "Entry", exact_text: true

        # Add a level from the foot row (prefilled next ordinal = 2).
        assert_equal "2", find("#level-editor-add-ordinal").value
        js_set_field "#level-editor-add-title", "Engineer II"
        js_set_field "#level-editor-add-code", "E2"
        page.execute_script(<<~JS)
          document.querySelector('#level-editor-add-title').closest('form').requestSubmit();
        JS
        assert_text "L2"
        assert_selector "input[name='level[title]'][value='Engineer II']"

        # Duplicate ordinal → in-frame error, list intact.
        js_set_field "#level-editor-add-ordinal", "1"
        js_set_field "#level-editor-add-title", "Dup"
        js_set_field "#level-editor-add-code", "D1"
        page.execute_script(<<~JS)
          document.querySelector('#level-editor-add-title').closest('form').requestSubmit();
        JS
        assert_text "already has a level at ordinal 1"
        assert_text "L2"
      end
    end
  end

  context "role kebab menu stacking" do
    # Regression: the kebab menu was clipped by the tree pane's overflow
    # containers (rendered "under" the matrix). JS-dispatched clicks bypass
    # hit-testing, so only a real elementFromPoint probe catches this class.
    should "open the menu fully visible and hit-testable above the matrix" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      page.execute_script(
        "document.querySelector(\"button[aria-label='Role actions']\").click();"
      )
      assert_selector "[role='menu']", visible: true, text: "Edit role…"

      # The fixed-position clamp runs in requestAnimationFrame after the menu
      # opens — poll until geometry is stable across reads before asserting.
      result = nil
      5.times do
        result = read_menu_geometry
        break if result["fixed"] && result["onScreen"] && result["allHit"]

        sleep 0.1
      end

      assert result["fixed"], "menu should use the fixed strategy"
      assert result["onScreen"], "menu must be fully on-screen, not clipped by the pane"
      assert result["allHit"], "every menu item must be the top-most element at its center"
    end
  end

  def read_menu_geometry
    page.evaluate_script(<<~JS)
        (() => {
          const menu = document.querySelector("[role='menu']:not(.hidden)");
          const items = [...menu.querySelectorAll("[role='menuitem']")];
          const rect = menu.getBoundingClientRect();
          return {
            fixed: getComputedStyle(menu).position === "fixed",
            onScreen: rect.left >= 0 && rect.right <= window.innerWidth,
            allHit: items.every(item => {
              const r = item.getBoundingClientRect();
              const el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
              return el === item || item.contains(el);
            })
          };
        })()
      JS
  end

  context "ghost org-structure entities (no published levels)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        # A live-added role with no levels in an existing family, and a
        # brand-new empty family — both invisible in the published view.
        handler.add_role(@framework_id, SecureRandom.uuid_v7, @rfid, "Engineering Manager", "EM", "management")
        handler.add_role_family(@framework_id, SecureRandom.uuid_v7, "Design")
      end
    end

    should "hide a ghost role and an empty family from the view-mode tree" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text "Test Framework"

      within "[data-controller~='tree']" do
        assert_text "Software Engineer"
        assert_no_text "Engineering Manager"
        assert_no_text "Design"
      end
    end

    should "show ghosts with the wiggle and an empty-family placeholder in edit mode" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      within "[data-controller~='tree']" do
        # Ghost role: rendered, wiggled, tooltip conveys the meaning non-visually.
        assert_selector "span.decoration-wavy[title*='Not in the published framework']",
                        text: "Engineering Manager"
        # Ghost (empty) family: rendered with wiggle + explicit emptiness.
        assert_selector "span.decoration-wavy[title*='Not in the published framework']",
                        text: "Design"
        assert_text "No roles yet"
        # A published role stays undecorated.
        assert_no_selector "span.decoration-wavy", text: "Software Engineer"
      end
    end
  end

  private

  # Clicks a hover-revealed control by its accessible name. Selenium reports an
  # opacity-0 control as not displayed, and pointer clicks on one flake on
  # starved CI — so assert it exists and dispatch the click via JS (the
  # archive-kebab precedent).
  def js_click_by_label(label)
    assert_selector "button[aria-label='#{label}']", visible: :all
    page.execute_script(<<~JS, label)
      document.querySelector(`button[aria-label='${arguments[0]}']`).click();
    JS
  end

  def open_kebab(label) = js_click_by_label(label)
  def open_row_kebab = open_kebab("Capability actions")

  # Clicks the OPEN kebab's menu item by its leading text, then waits for the
  # result so the click is committed before the next step. Every kebab's menu is
  # in the DOM at once (only the open one is displayed), so filter on visibility
  # — matching on text alone hits whichever menu rendered first.
  def click_menu_item(label, expect_text:)
    assert_text label
    page.execute_script(<<~JS, label)
      [...document.querySelectorAll("[role='menuitem']")]
        .filter((b) => b.offsetParent !== null)
        .find((b) => b.textContent.trim().startsWith(arguments[0])).click();
    JS
    assert_text expect_text
  end

  # Both of these are now thin aliases over the shared +js_fill_in+ helper,
  # which this file's local versions predated.
  def js_set_field(selector, value)
    js_fill_in(selector, with: value)
  end

  # The debounced framework-explorer capability filter reads the exact query,
  # so it must not be typed character by character.
  def set_search_query(query)
    js_fill_in("[data-framework-search-target='input']", with: query)
  end
  context "reordering capabilities" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        # A second capability in the same category so the kebab move items
        # render, bound to the role so it is visible in the filtered matrix.
        h = Frameworks::CommandHandler.new
        cap2 = SecureRandom.uuid_v7
        h.add_capability(@framework_id, cap2, SecureRandom.uuid_v7,
                         FrameworkState::CapabilityCategory.find_by!(name: "Thinking").category_id,
                         "Critical Thinking")
        h.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap2, @rid)
        h.publish_version(@framework_id, "cap2")
      end
    end

    should "move a capability up via the row kebab and re-render in the new order" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_text "Critical Thinking"

      # The second capability row's kebab — "Move up" is a menu item, the ONE
      # reorder treatment (#380).
      moving_row = find("tr[data-capability-id]", text: "Critical Thinking", match: :first)
      use_explorer_menu("Capability actions", "Move up",
                        scope: "tr[data-capability-id='#{moving_row[:'data-capability-id']}']")

      # Assert by capability id + document order (general-sibling combinator),
      # not row position — the tr count shifts as rows are added around the
      # list (header rows, expanded rows, the add-capability row).
      moved_id = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::Capability.find_by!(name: "Critical Thinking").capability_id
      end
      other_id = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::Capability.find_by!(name: "Strategic Thinking").capability_id
      end
      assert_selector "tr[data-capability-id='#{moved_id}'] ~ tr[data-capability-id='#{other_id}']"

      ActsAsTenant.with_tenant(@tenant) do
        ordered = FrameworkState::Capability
          .where(name: [ "Strategic Thinking", "Critical Thinking" ])
          .order(:ordinal, :id).pluck(:name)
        assert_equal [ "Critical Thinking", "Strategic Thinking" ], ordered
      end
    end
  end

  context "reordering categories" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        # A second category so the header kebab offers Move up/down.
        Frameworks::CommandHandler.new.add_capability_category(
          @framework_id, SecureRandom.uuid_v7, "Delivery", ordinal: 2
        )
      end
    end

    should "move a category up via the header kebab and re-render in the new order" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_text "Delivery"

      # Reorder is a kebab item everywhere now (#380) — the second category's
      # menu is the first one offering "Move up".
      use_explorer_menu("Category actions", "Move up", index: 1)

      # There is ONE <tbody> per category (§11b), so "tbody tr:first-child"
      # matched the first row of EVERY category — true whichever order they
      # sit in. Assert document order between the two groups instead, which
      # also waits for the move: reorder-move repositions the node only after
      # the server answers ok.
      moved_id, other_id = ActsAsTenant.with_tenant(@tenant) do
        %w[Delivery Thinking].map do |name|
          FrameworkState::CapabilityCategory.find_by!(name: name).category_id
        end
      end
      assert_selector "tbody[data-category-group='#{moved_id}'] ~ " \
                      "tbody[data-category-group='#{other_id}']"

      ActsAsTenant.with_tenant(@tenant) do
        ordered = FrameworkState::CapabilityCategory
          .where(framework_id: @framework_id, status: "active")
          .order(:ordinal, :id).pluck(:name)
        assert_equal [ "Delivery", "Thinking" ], ordered
      end
    end

    should "offer no category kebab in view mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      # The empty "Delivery" category is hidden in view mode (Lesson 18) —
      # sync on the published category instead.
      assert_text "Thinking"
      assert_no_selector "button[data-menu='category']", visible: :all
    end
  end

  context "reordering illustrations" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        # A second illustration so the Move up/down items render (they need >1).
        # Illustration adds are shape-preserving, so post-publish is live.
        Frameworks::CommandHandler.new.add_role_illustration(
          @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
          @eid, @rid, 2, "Beta second illustration"
        )
      end
    end

    should "move an illustration up via the kebab and persist the order" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Beta second illustration"

      # Reorder is a kebab item everywhere now (#380); the second illustration
      # is the one that can move up.
      use_explorer_menu("Example actions", "Move up", index: 1)

      # The reorder-list controller repositions the frame only after the
      # server answers 204, so DOM order flipping proves the round trip.
      assert_selector "ul[id^='illustrations-'] turbo-frame:first-of-type",
                      text: "Beta second illustration"

      ActsAsTenant.with_tenant(@tenant) do
        ordered = FrameworkState::RoleIllustration
          .where(expectation_id: @eid, role_id: @rid)
          .order(:ordinal, :id).pluck(:description)
        assert_equal [ "Beta second illustration", "Seeks guidance from tech lead" ], ordered
      end
    end

    # Every other Move surface omits the direction it can't take; the
    # illustration menu reads its position from the DOM at open time, because an
    # in-place move reorders the list without re-rendering the trigger.
    should "offer only the move directions the illustration actually has" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Beta second illustration"

      open_explorer_menu("Example actions", index: 0)
      assert_no_selector "[data-explorer-menu] [role='menuitem']", text: "Move up"
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Move down"
      press_escape

      open_explorer_menu("Example actions", index: 1)
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Move up"
      assert_no_selector "[data-explorer-menu] [role='menuitem']", text: "Move down"
    end

    # …and the DOM is the source of truth: after an in-place move the SAME
    # trigger must offer the opposite direction, with no re-render in between.
    should "follow the illustration to its new position after a move" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Beta second illustration"

      use_explorer_menu("Example actions", "Move up", index: 1)
      assert_selector "ul[id^='illustrations-'] turbo-frame:first-of-type",
                      text: "Beta second illustration"

      # The moved item is now first — its menu offers Move down only.
      open_explorer_menu("Example actions", index: 0)
      assert_no_selector "[data-explorer-menu] [role='menuitem']", text: "Move up"
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Move down"
    end

    should "offer no illustration kebab in view mode" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Beta second illustration"
      assert_no_selector "button[data-menu='illustration']", visible: :all
    end
  end

  # Starting a discussion from the grid — the "Discuss…" affordances (§12a).
  # The admin is a tenant admin, which clears the suggest bar.
  context "starting a discussion" do
    should "ask about an expectation from the cell and land on its card" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      js_click_by_label "Discuss this expectation"
      assert_selector "#request-clarification-modal", visible: true
      assert_text "Strategic Thinking · L1"

      within "#request-clarification-modal" do
        js_set_field "#clarification_rationale", "Does this mean asking in writing or in the room?"
        page.execute_script("arguments[0].requestSubmit();", find("form", match: :first))
      end

      # The pane swaps to the new discussion's card (suggestion:open-card).
      assert_text "Does this mean asking in writing or in the room?"

      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.clarifications.pending.last
        assert_equal "behavioural_expectation", row.target_entity_type
        assert_equal @eid, row.target_entity_id
      end
    end

    should "ask about a capability from the row kebab, choosing the level" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      open_row_kebab
      click_menu_item "Discuss…", expect_text: "Start a discussion"
      assert_selector "#request-clarification-modal", visible: true

      within "#request-clarification-modal" do
        # The row names no cell, so the level is chosen here.
        assert_selector "#clarification_level_ordinal", visible: true
        js_set_field "#clarification_rationale", "How does this differ from Judgement?"
        page.execute_script("arguments[0].requestSubmit();", find("form", match: :first))
      end

      assert_text "How does this differ from Judgement?"
      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.clarifications.pending.last
        assert_equal "capability", row.target_entity_type
        assert_equal @cap_id, row.target_entity_id
      end
    end

    should "ask about one example from the illustration kebab" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"

      open_kebab "Example actions"
      click_menu_item "Discuss…", expect_text: "Start a discussion"
      assert_selector "#request-clarification-modal", visible: true
      assert_text "Strategic Thinking · L1 · Software Engineer example"

      within "#request-clarification-modal" do
        js_set_field "#clarification_rationale", "Is tech-lead guidance the right E1 example?"
        page.execute_script("arguments[0].requestSubmit();", find("form", match: :first))
      end

      assert_text "Is tech-lead guidance the right E1 example?"
      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.clarifications.pending.last
        assert_equal "role_illustration", row.target_entity_type
        assert_equal @ill_id, row.target_entity_id
        assert_equal 1, row.proposed_attributes["level_ordinal"]
      end
    end

    # The kebab menu (z-50) outranks the modal overlay (z-40), and clicking a
    # menu item isn't an "outside" click — so without an explicit close the
    # menu renders over the dialog it just launched.
    should "close the kebab menu when it opens the modal" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      open_row_kebab
      click_menu_item "Discuss…", expect_text: "Start a discussion"
      assert_selector "#request-clarification-modal", visible: true

      assert_no_selector "[role='menuitem']", visible: true
    end

    should "reach the modal on a narrow viewport" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      open_row_kebab
      click_menu_item "Discuss…", expect_text: "Start a discussion"
      assert_selector "#request-clarification-modal", visible: true
    end

    should "offer no Discuss affordance in view mode" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text "Strategic Thinking"

      assert_no_selector "button[aria-label='Discuss this expectation']", visible: :all
      assert_no_selector "#request-clarification-modal", visible: :all
      assert_no_selector "button[aria-label='Capability actions']", visible: :all
    end
  end

  context "clarifications" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @author = FactoryBot.create(:person, tenant: @tenant, name: "Quinn Questioner")
        @clarification_id = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.request_clarification(
          @framework_id, @clarification_id, "behavioural_expectation", @eid,
          author_id: @author.id.to_s,
          rationale: "Raters read 'clarifying questions' three different ways"
        )
      end
    end

    should "show the comment glyph on the cell in edit mode, never the wiggle or view mode" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      # The glyph is the content language for "a discussion exists"…
      assert_selector "[data-glyph='clarification']", visible: :all
      # …and deliberately NOT the pending-change wiggle: the expectation text
      # renders undecorated (a clarification proposes nothing).
      assert_no_selector "td .decoration-suggestion-edit", text: "Asks clarifying questions"

      visit framework_path(@framework_id)
      assert_no_text "Edit mode", exact: true
      assert_no_selector "[data-glyph='clarification']", visible: :all
    end

    should "surface the glyph and reach the resolve modal on a narrow viewport" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      # The glyph rides the matrix cell at every breakpoint — the matrix is
      # full-width on narrow because the pane is a slide-over there (#384), so
      # the feed (and its Resolve…) is behind the Activity toggle.
      assert_selector "[data-glyph='clarification']", visible: :all
      toggle_context_pane
      assert_text "Asked for clarification"

      click_button_with_js_fallback "Resolve…", expect_text: "Resolve clarification"
      assert_selector "#resolve-clarification-modal", visible: true
    end

    should "open the discussion card by clicking the cell glyph" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      # The glyph is the way into the discussion from the grid — click it and
      # the pane swaps to that clarification's card.
      # The author's name is already in the feed; the card's back link is not.
      click_selector_with_js_fallback "[data-glyph='clarification'][data-suggestion-id]",
                                      expect_text: "Back to activity"
      assert_text "Raters read 'clarifying questions' three different ways"
    end

    # The glyph opens the newest discussion; the card lists its siblings, so
    # the second one is one click away rather than only in the feed.
    should "reach both discussions on a cell from the glyph" do
      second_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.request_clarification(
          @framework_id, second_id, "behavioural_expectation", @eid,
          author_id: @author.id.to_s, rationale: "And does 'clarifying' mean challenging?"
        )
      end

      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      # Both questions are already on screen in the feed, so assert on state
      # only the click can produce — the card, and the URL it focuses.
      click_selector_with_js_fallback "[data-glyph='clarification'][data-suggestion-id]",
                                      expect_text: "Back to activity"
      assert_includes current_url, "suggestion_id=#{second_id}"
      assert_text "1 OTHER DISCUSSION HERE"

      # …and its sibling opens its own card, which the URL must follow.
      # A card is already open, so its back link can't be the signal — the
      # siblings list flipping to name the OTHER discussion is.
      click_selector_with_js_fallback(
        "#discussion-siblings button",
        expect_selector: "#discussion-siblings button[data-suggestion-id='#{second_id}']"
      )
      assert_no_current_path(/suggestion_id=#{second_id}/, url: true)
      assert_includes current_url, "suggestion_id=#{@clarification_id}"
    end

    # An illustration-anchored discussion is invisible on a collapsed row
    # unless the compact cell counts it.
    should "surface a discussion on an example from the collapsed cell" do
      question = "Is tech-lead guidance the right E1 example?"
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.request_clarification(
          @framework_id, SecureRandom.uuid_v7, "role_illustration", @ill_id,
          author_id: @author.id.to_s, level_ordinal: 1, rationale: question
        )
      end

      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      # Row is collapsed — the cell's glyph is the only signal it exists.
      assert_no_selector "tr[data-matrix-target='expandedRow']", visible: true
      # The question is already in the feed, so sync on card-only text.
      click_selector_with_js_fallback "[data-glyph='clarification'][data-suggestion-id]",
                                      expect_text: "Back to activity"
      assert_text question
    end

    # Resolve… sits over the entry's Discuss link, and the modal's footer
    # buttons sit at the bottom of its scroll box: an unchecked hit area takes
    # the link's taps in one and gives the other a scrollbar.
    should "keep Resolve… and the modal's buttons to their own space" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Asked for clarification"
      assert_no_stolen_taps

      click_button_with_js_fallback "Resolve…", expect_text: "Resolve clarification"
      assert_selector "#resolve-clarification-modal", visible: true
      scrolls = page.evaluate_script(<<~JS)
        (() => {
          const body = document.querySelector("#resolve-clarification-modal [data-modal-target='panel'] > .overflow-y-auto");
          return body.scrollHeight > body.clientHeight || body.scrollWidth > body.clientWidth;
        })()
      JS
      assert_not scrolls, "the resolve modal's body scrolls with nothing to scroll to"
    end

    should "resolve a clarification from the feed via the modal" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Asked for clarification"
      assert_text "Raters read 'clarifying questions' three different ways"

      click_button_with_js_fallback "Resolve…", expect_text: "Resolve clarification"
      within "#resolve-clarification-modal" do
        # The exact note is asserted on the read model — JS assignment so
        # send_keys can't drop characters on starved CI.
        js_set_field "#resolve_note", "Reworded the L1 expectation"
        page.execute_script("arguments[0].requestSubmit();", find("form", match: :first))
      end

      # Feed reloads off the activity broadcast with the resolution entry.
      assert_text "Resolved a clarification"
      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.find_by!(suggestion_id: @clarification_id)
        assert_equal "resolved", row.status
        assert_equal "Reworded the L1 expectation", row.reviewer_comment
      end
    end
  end
end
