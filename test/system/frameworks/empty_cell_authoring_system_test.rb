# frozen_string_literal: true

require "application_system_test_case"

# Authoring a behavioural expectation in an empty-but-applicable matrix cell
# (edit mode). The cell offers "+ Add expectation"; submitting it stages the new
# expectation into a draft. A not-applicable / filled cell offers nothing.
class Frameworks::EmptyCellAuthoringSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      # Two live levels — so level 2 is a genuine empty-but-applicable cell.
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 2, "Engineer II", "E2")
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @role_id)
      # Authored at level 1 only — level 2 is the empty cell under test.
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "test")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  # Visit edit mode with the role pre-selected so its level columns (and the
  # empty level-2 cell) render.
  def visit_edit(size: DESKTOP_SIZE)
    page.driver.browser.manage.window.resize_to(*size)
    sign_in_as(@admin_user)
    visit edit_framework_path(@framework_id, roles: [ @role_id ])
    wait_for_stimulus "matrix"
  end

  context "as a tenant admin in edit mode" do
    should "offer + Add expectation on the empty applicable cell and author one" do
      visit_edit

      # The empty level-2 cell exposes the authoring affordance (hover-revealed).
      assert_selector "button[data-inline-editor-target='display']", text: "Add expectation", visible: :all

      # Reveal the inline form (JS-click the opacity-0 control), fill, and submit
      # via requestSubmit (the form redirects on success — testing.md JS-submit).
      page.execute_script(<<~JS)
        [...document.querySelectorAll("button[data-inline-editor-target='display']")]
          .find((b) => b.textContent.includes("Add expectation")).click();
      JS
      # Set the textarea via JS value-dispatch — Selenium send_keys can drop
      # characters on starved CI and the assertion depends on this value
      # (testing.md). Then submit the (redirecting) form.
      page.execute_script(<<~JS, find("textarea[name='behavioural_expectation[description]']"))
        const el = arguments[0];
        el.value = "Identifies root causes";
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      JS
      page.execute_script('document.querySelector("form[action$=\'/expectations\']").requestSubmit();')

      assert_text "Added an expectation"
      assert_text(/draft/i) # a draft was auto-opened by the shape-changing add
    end
  end

  context "as a tenant admin on a mobile viewport" do
    should "still expose the + Add expectation affordance" do
      visit_edit(size: MOBILE_SIZE)
      assert_selector "button[data-inline-editor-target='display']", text: "Add expectation", visible: :all
    end
  end
end
