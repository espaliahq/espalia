# frozen_string_literal: true

require "application_system_test_case"

class FrameworksSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user)

      # Create a minimal framework with structure via events
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
      handler.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, eid, rid, 1, "Seeks guidance from tech lead")

      # Publish v1 so shape-changing events land in the read model
      handler.publish_version(@framework_id, "test")
    end

    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "frameworks index" do
    should "show the framework in the listing" do
      visit frameworks_path

      assert_text "Frameworks"
      assert_text "Test Framework"
    end

    should "navigate to framework show page" do
      visit frameworks_path

      # Wait for the index to fully render before clicking through. Without
      # this synchronisation, the click can land on a stale link and be
      # silently dropped on slow CI runners.
      assert_text "Frameworks"
      click_link "Test Framework"

      assert_text "Strategic Thinking"
      assert_text "Engineering"
    end
  end

  context "framework show" do
    should "display role tree and matrix" do
      visit framework_path(@framework_id)

      # Role tree is visible on desktop
      assert_text "Roles"
      assert_text "Engineering"
      assert_text "Software Engineer"

      # Matrix header (full title shown when few roles selected)
      assert_text "Level 1"
      assert_text "Engineer I"
    end

    should "display capabilities with expectations in matrix" do
      visit framework_path(@framework_id)

      # Category and capability in matrix
      assert_text "Thinking"
      assert_text "Strategic Thinking"
      assert_text "Asks clarifying questions"
    end
  end

  context "navbar navigation" do
    should "include framework link in navbar" do
      visit root_path

      within "nav" do
        # Singular "Framework" when only one exists
        assert_text "Framework"
      end
    end
  end
end
