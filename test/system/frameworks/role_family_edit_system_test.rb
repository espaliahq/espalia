# frozen_string_literal: true

require "application_system_test_case"

# The role-family edit dialog (edit mode) — name + description + department.
# Moving a family between department groupings is editing its `department`
# string; the tree's family list re-renders so the family lands under its new
# (or a brand-new) department header. View mode shows no edit affordance.
class Frameworks::RoleFamilyEditSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @backend_rf = SecureRandom.uuid_v7
      @frontend_rf = SecureRandom.uuid_v7
      backend_role = SecureRandom.uuid_v7
      frontend_role = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      # Backend starts ungrouped; Frontend is already in "Engineering" so the
      # datalist has an existing option to reuse.
      handler.add_role_family(@framework_id, @backend_rf, "Backend")
      handler.add_role_family(@framework_id, @frontend_rf, "Frontend", department: "Engineering")
      handler.add_role(@framework_id, backend_role, @backend_rf, "Backend Engineer", "BE", "ic")
      handler.add_role(@framework_id, frontend_role, @frontend_rf, "Frontend Engineer", "FE", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, backend_role, 1, "BE I", "BE1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, frontend_role, 1, "FE I", "FE1", is_entry: true)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "edit mode" do
    should "move a family into a new department via the edit dialog" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Backend"

      open_family_edit_modal(@backend_rf)
      # The datalist offers the existing "Engineering" group.
      assert_selector "datalist#role-family-departments option[value='Engineering']", visible: :all

      set_department_and_save("Finance")

      # Family re-groups: a new FINANCE header appears (uppercased via CSS),
      # ENGINEERING still holds Frontend, and the modal closes.
      assert_text(/finance/i)
      assert_text(/engineering/i)
      assert_no_selector "#role-family-edit-modal", visible: true
    end

    should "prefill the dialog from the family being edited" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Frontend"

      open_family_edit_modal(@frontend_rf)
      assert_equal "Frontend", find("#role_family_edit_name").value
      assert_equal "Engineering", find("#role_family_edit_department").value
    end

    # The edit trigger lives in the role pane, which is an overlay on narrow
    # viewports — reachable once the pane is toggled open.
    should "reach the edit dialog on a narrow viewport via the role pane overlay" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      toggle_role_pane

      open_family_edit_modal(@backend_rf)
      assert_equal "Backend", find("#role_family_edit_name").value
    end
  end

  context "view mode" do
    should "show no role-family edit trigger" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text "Backend"
      assert_no_selector "[data-modal-target-id='role-family-edit-modal']"
    end
  end

  private

  # JS-click the hover-revealed edit trigger (opacity-0 Selenium pointer clicks
  # flake on starved CI) and wait for the shared modal to open.
  def open_family_edit_modal(role_family_id)
    page.execute_script(
      "document.querySelector(`[data-role-family-edit-id='${arguments[0]}']`).click();",
      role_family_id
    )
    assert_selector "#role-family-edit-modal", visible: true
  end

  # Set the department field via JS (send_keys drops chars on starved CI) and
  # submit the form synchronously (Turbo re-renders the families frame).
  def set_department_and_save(value)
    page.execute_script(<<~JS, value)
      const input = document.querySelector("#role_family_edit_department");
      input.value = arguments[0];
      input.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    page.execute_script("document.querySelector('#role-family-edit-modal form').requestSubmit();")
  end
end
