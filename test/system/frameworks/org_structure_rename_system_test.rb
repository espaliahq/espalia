# frozen_string_literal: true

require "application_system_test_case"

# Inline rename of org-structure entities (role family + role in the left tree,
# level title in the matrix header) in edit mode. These are direct edits — the
# new value applies live (no pending decoration). View mode renders plain names
# with no edit affordance.
class Frameworks::OrgStructureRenameSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @viewer_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @viewer_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @level_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, @rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @role_id)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "edit mode" do
    should "rename a role family inline in the tree" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      submit_inline_rename("role-family-name-#{@rf_id}", "role_family[name]", "Platform Engineering")
      assert_text "Platform Engineering"
    end

    should "rename a role inline in the tree" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      submit_inline_rename("role-name-#{@role_id}", "role[name]", "Backend Engineer")
      assert_text "Backend Engineer"
    end

    should "rename a level title inline in the matrix header" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      submit_inline_rename("level-title-#{@level_id}", "level[title]", "Engineer One")
      assert_text "Engineer One"
    end
  end

  context "view mode" do
    should "render plain names with no edit affordance across the whole rename surface" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text "Software Engineer"
      # Tree: no role / role-family inline editors or pencils.
      assert_no_selector "turbo-frame#role-name-#{@role_id} [data-controller='inline-editor']"
      assert_no_selector "[aria-label='Edit role name']"
      assert_no_selector "[aria-label='Edit role family name']"
      # Matrix header: no level-title inline editor or pencil.
      assert_text "Engineer I"
      assert_no_selector "turbo-frame#level-title-#{@level_id} [data-controller='inline-editor']"
      assert_no_selector "[aria-label='Edit level title']"
    end
  end

  private

  # Reveal the hidden inline-editor form inside a turbo-frame, set the textarea
  # via JS (Selenium send_keys drops chars on starved CI), and submit the form
  # synchronously — the same JS-dispatch pattern the other inline editors use.
  def submit_inline_rename(frame_id, field_name, value)
    editor = find("turbo-frame##{frame_id} > div")
    page.execute_script(
      "arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", editor
    )
    page.execute_script(
      "arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", editor
    )
    page.execute_script(<<~JS, editor, field_name, value)
      const ta = arguments[0].querySelector(`textarea[name='${arguments[1]}']`);
      ta.value = arguments[2];
      ta.dispatchEvent(new Event("input", { bubbles: true }));
      ta.dispatchEvent(new Event("change", { bubbles: true }));
    JS
    page.execute_script("arguments[0].querySelector('form').requestSubmit();", editor)
  end
end
