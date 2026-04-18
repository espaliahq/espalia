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

      textarea = editor.find("textarea[name='capability[name]']")
      textarea.fill_in with: "Sharper Strategic Thinking"
      editor.find("button[type='submit']", match: :first).click

      # Turbo swaps the frame; the updated name and wavy-underline decoration
      # (pending edit) both appear.
      assert_text "Sharper Strategic Thinking"
      assert_no_text "Strategic Thinking", exact: true
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
      find("button[data-edit-mode-toggle-target='suggestingButton']").click

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
      editor.find("button[type='submit']", match: :first).click

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
    end
  end

  private

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end
end
