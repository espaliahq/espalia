# frozen_string_literal: true

require "application_system_test_case"

# Inline rename of the framework itself from the explorer's edit-mode header
# (#405). A direct edit like the org-structure renames — the new name applies
# live, with no pending decoration — but gated narrower: tenant admin or
# framework OWNER. An editor sees the heading with no pencil.
class Frameworks::FrameworkRenameSystemTest < ApplicationSystemTestCase
  # DESKTOP_SIZE / MOBILE_SIZE and the desktop reset in setup come from
  # ApplicationSystemTestCase.
  setup do
    @tenant = FactoryBot.create(:tenant)
    @owner_user = FactoryBot.create(:user, password: "password123")
    @editor_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      owner = FactoryBot.create(:person, tenant: @tenant, email: @owner_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: owner)
      editor = FactoryBot.create(:person, tenant: @tenant, email: @editor_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @editor_user, role: :member, person: editor)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rf_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework", created_by: owner.id)
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, role_id, rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, role_id)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "test")
      FactoryBot.create(:framework_collaborator, tenant: @tenant, framework_id: @framework_id,
                                                 person_id: editor.id, role: "editor")
    end
  end

  context "as the framework owner" do
    should "rename from the header pencil on desktop, and see it on the index" do
      sign_in_as(@owner_user)
      visit edit_framework_path(@framework_id)
      assert_selector "h1", text: "Test Framework"

      submit_framework_rename("Engineering Career Path")
      assert_selector "h1", text: "Engineering Career Path"
      assert_no_selector "[data-editor-form]"

      visit frameworks_path
      assert_text "Engineering Career Path"
      assert_no_text "Test Framework"
    end

    # The frame is shrink-to-fit, so without the floor the editor would open
    # only as wide as the short current name. The heading is measured BEFORE
    # the editor opens — the editor hides it, so it would read 0 afterwards.
    should "open a roomy editor on desktop even for a short name" do
      sign_in_as(@owner_user)
      visit edit_framework_path(@framework_id)
      heading_width = find("h1", text: "Test Framework").evaluate_script("this.getBoundingClientRect().width")

      form = start_inline_edit(host_selector)
      form_width = form.evaluate_script("this.getBoundingClientRect().width")
      assert_operator form_width, :>=, 384, "editor should be at least 24rem wide on desktop"
      assert_operator form_width, :>, heading_width, "the floor must beat the pinned heading width"
      cancel_inline_edit(form)
    end

    # Below sm the frame goes full-width instead (a 24rem floor would overflow
    # a phone), so a short name still gets the whole line.
    should "open a full-width editor on mobile even for a short name" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@owner_user)
      visit edit_framework_path(@framework_id)
      heading_width = find("h1", text: "Test Framework").evaluate_script("this.getBoundingClientRect().width")

      form = start_inline_edit(host_selector)
      form_width = form.evaluate_script("this.getBoundingClientRect().width")
      assert_operator form_width, :>, heading_width, "the editor must not pin to the short name's width"
      assert_operator form_width, :>=, 300, "the editor should span the phone's content width"
      # The window's width includes the scrollbar, so compare the document's own client width. Opening the
      # editor can bring in the scrollbar a frame after layout, so wait for the widths to settle.
      overflow = "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      begin
        page.document.synchronize { raise Capybara::ExpectationNotMet unless page.evaluate_script(overflow).zero? }
      rescue Capybara::ExpectationNotMet
        flunk "no sideways overflow: #{page.evaluate_script(overflow)}px"
      end
      cancel_inline_edit(form)
    end

    should "rename from the header pencil on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@owner_user)
      visit edit_framework_path(@framework_id)
      assert_selector "h1", text: "Test Framework"

      submit_framework_rename("Mobile Renamed")
      assert_selector "h1", text: "Mobile Renamed"
    end

    should "show the error inline and keep the typed text when the name is blank" do
      sign_in_as(@owner_user)
      visit edit_framework_path(@framework_id)
      assert_selector "h1", text: "Test Framework"

      submit_framework_rename("   ")
      assert_text "Couldn’t save:"
      # The editor re-opens seeded with the attempted text, so nothing is lost.
      within host_selector do
        assert_selector "[data-editor-form]", visible: true
        assert_equal "   ", find("[data-editor-input]").value
      end
      # The persisted name is untouched.
      assert_selector "h1", text: "Test Framework", visible: :all
    end
  end

  context "as an editor collaborator" do
    should "see the heading with no rename pencil" do
      sign_in_as(@editor_user)
      visit edit_framework_path(@framework_id)
      assert_selector "h1", text: "Test Framework"
      assert_selector "[data-controller~='field-editor']", visible: :all
      assert_no_selector "[aria-label='Edit framework name']", visible: :all
      assert_no_selector "#{host_selector}[data-editor-action]", visible: :all
    end
  end

  context "view mode" do
    should "render the plain heading with no edit affordance, even for the owner" do
      sign_in_as(@owner_user)
      visit framework_path(@framework_id)
      assert_selector "h1", text: "Test Framework"
      assert_no_selector "[aria-label='Edit framework name']", visible: :all
    end
  end

  private

  def host_selector
    "turbo-frame#framework-name-#{@framework_id} > div"
  end

  # Open the shared inline editor on the name frame's host and save the new
  # value — the JS-dispatch pattern the org-structure renames use.
  def submit_framework_rename(value)
    form = start_inline_edit(host_selector)
    assert_equal "framework[name]", form.find("[data-editor-input]", visible: :all)[:name]
    # A direct edit with no approval tier — the editor always says "Save".
    assert_equal "Save", form.find("[data-editor-submit]").text
    submit_inline_edit(form, with: value)
  end
end
