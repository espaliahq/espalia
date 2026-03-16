# frozen_string_literal: true

require "application_system_test_case"

class FrameworksIllustrationsSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks clarifying questions")
      handler.add_role_illustration(
        @framework_id, @ill_id, SecureRandom.uuid_v7, eid, rid, 1, "Seeks guidance from tech lead"
      )
    end

    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "inline illustration editing" do
    should "expand row and show illustration text" do
      visit framework_path(@framework_id)

      # Expand the capability row by clicking it
      find("tr[data-capability-id]", match: :first).click

      # Illustration is now visible in the expanded row
      assert_text "Seeks guidance from tech lead"
    end

    should "allow saving updated illustration text inline" do
      visit framework_path(@framework_id)

      # Expand the capability row
      find("tr[data-capability-id]", match: :first).click
      assert_text "Seeks guidance from tech lead"

      # The inline-editor controller is on each illustration li.
      # Trigger startEdit via JS (simulates hover + click on the hidden edit button)
      ill_li = find("li[data-controller='inline-editor']", match: :first)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", ill_li)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", ill_li)

      # Fill in the textarea and submit
      textarea = ill_li.find("textarea[name='illustration[description]']")
      textarea.fill_in with: "Proactively seeks guidance and asks clarifying questions"

      ill_li.find("button[type='submit']", match: :first).click

      # Turbo frame swap: updated text appears inline
      assert_text "Proactively seeks guidance and asks clarifying questions"
      assert_no_text "Seeks guidance from tech lead"
    end

    should "cancel editing and restore original text" do
      visit framework_path(@framework_id)

      find("tr[data-capability-id]", match: :first).click
      assert_text "Seeks guidance from tech lead"

      ill_li = find("li[data-controller='inline-editor']", match: :first)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", ill_li)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", ill_li)

      textarea = ill_li.find("textarea[name='illustration[description]']")
      textarea.fill_in with: "This should not be saved"

      ill_li.find("button[data-action='inline-editor#cancel']", match: :first).click

      # Edit form hidden, display mode restored — original text visible
      assert_text "Seeks guidance from tech lead"
    end
  end
end
