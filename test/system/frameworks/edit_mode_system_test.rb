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

    should "hide the context pane by default" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_no_selector "[data-framework-explorer-target='contextPane']:not(.hidden)"
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

  private

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end
end
