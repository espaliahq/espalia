# frozen_string_literal: true

require "application_system_test_case"

# Inline-renaming a department group header relabels every role family in that
# group at once (a department is a free-text grouping label, not an entity).
# View mode shows a plain header with no edit affordance.
class Frameworks::DepartmentRenameSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      fc = SecureRandom.uuid_v7
      fo = SecureRandom.uuid_v7
      eng = SecureRandom.uuid_v7
      # Two families share "Finance"; one is in "Engineering".
      handler.create_framework(@framework_id, "Org")
      handler.add_role_family(@framework_id, fc, "Financial Control", department: "Finance")
      handler.add_role_family(@framework_id, fo, "Finance Operations", department: "Finance")
      handler.add_role_family(@framework_id, eng, "Engineering", department: "Engineering")
      handler.add_role(@framework_id, SecureRandom.uuid_v7, fc, "Controller", "FC", "ic")
      handler.add_role(@framework_id, SecureRandom.uuid_v7, fo, "Ops", "FO", "ic")
      handler.add_role(@framework_id, SecureRandom.uuid_v7, eng, "Engineer", "E", "ic")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "edit mode" do
    should "rename a department header across every family in the group" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_selector "input[name='department[from]'][value='Finance']", visible: :all

      rename_department("Finance", "Commercial Finance")

      # The header is renamed (the group's hidden from-value updates) and the
      # old "Finance" group is gone, while "Engineering" is untouched.
      assert_selector "input[name='department[from]'][value='Commercial Finance']", visible: :all
      assert_no_selector "input[name='department[from]'][value='Finance']", visible: :all
      assert_selector "input[name='department[from]'][value='Engineering']", visible: :all
      # Both families moved with the rename.
      assert_text "Financial Control"
      assert_text "Finance Operations"
    end

    # The header lives in the role pane, an overlay on narrow viewports —
    # reachable once toggled open.
    should "rename a department on a narrow viewport via the role pane overlay" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      toggle_role_pane
      assert_selector "input[name='department[from]'][value='Finance']", visible: :all

      rename_department("Finance", "Commercial Finance")

      assert_selector "input[name='department[from]'][value='Commercial Finance']", visible: :all
      assert_no_selector "input[name='department[from]'][value='Finance']", visible: :all
    end
  end

  context "view mode" do
    should "render department headers with no rename affordance" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text(/finance/i)
      assert_no_selector "[aria-label='Rename department']"
      assert_no_selector "input[name='department[from]']", visible: :all
    end
  end

  private

  # Reveal a department header's inline editor, set the new label, and submit —
  # the JS-dispatch pattern the other inline editors use (Selenium clicks on the
  # opacity-0 pencil + send_keys both flake on starved CI).
  def rename_department(from, to)
    container = find("input[name='department[from]'][value='#{from}']", visible: :all)
      .ancestor("[data-controller~='inline-editor']")
    page.execute_script(
      "arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", container
    )
    page.execute_script(
      "arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", container
    )
    page.execute_script(<<~JS, container, to)
      const input = arguments[0].querySelector("input[name='department[to]']");
      input.value = arguments[1];
      input.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    page.execute_script("arguments[0].querySelector('form').requestSubmit();", container)
  end
end
