# frozen_string_literal: true

require "application_system_test_case"

class FrameworkExplorerSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

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
      FrameworkState::RoleFamily.find_by!(role_family_id: @pd_family_id).update!(department: "Product + Engineering")

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
      FrameworkState::RoleFamily.find_by!(role_family_id: @eng_family_id).update!(department: "Product + Engineering")

      # ── Department: Finance ──
      # Role family: Financial Control
      @fc_family_id = SecureRandom.uuid_v7
      @fc_role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, @fc_family_id, "Financial Control")
      handler.add_role(@framework_id, @fc_role_id, @fc_family_id, "Financial Controller", "FC", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @fc_role_id, 1, "Junior Financial Controller", "FC1", is_entry: true)
      FrameworkState::RoleFamily.find_by!(role_family_id: @fc_family_id).update!(department: "Finance")

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
    end

    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
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

      # Expand the capability row by clicking it
      find("[data-capability-id]", match: :first).click

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

  context "responsive behaviour" do
    should "show role tree inline on desktop" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit framework_path(@framework_id)

      assert_selector "[data-framework-explorer-target='rolePane']", visible: true
      assert_no_selector "button", text: "Roles", visible: true
    end

    should "hide role tree on mobile and show it via toggle button" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit framework_path(@framework_id)

      # Role pane should be hidden on mobile
      assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true

      # Toggle button should be visible
      assert_selector "button", text: "Roles", visible: true

      # Click toggle to show role tree
      click_button "Roles"

      # Role tree should now be visible as overlay
      assert_selector "[data-framework-explorer-target='rolePane']", visible: true
      assert_text "Product Design"
      assert_text "Software Engineering"
    end

    should "close mobile role tree overlay when clicking outside" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit framework_path(@framework_id)

      # Open the role pane
      click_button "Roles"
      assert_selector "[data-framework-explorer-target='rolePane']", visible: true

      # Click outside the role pane (right side of viewport, past the 18rem overlay)
      page.driver.browser.action.move_to_location(350, 400).click.perform

      # Role pane should close
      assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true
    end
  end
end
