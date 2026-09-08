# frozen_string_literal: true

require "application_system_test_case"

# The matrix ships every capability's expanded row as a hidden placeholder and
# fetches the illustrations the first time the row is expanded — the expanded
# rows were 81% of the edit-mode payload for rows the accordion never shows
# (framework-explorer.md, lazy-row lesson). These tests pin the contract in
# both modes and at both viewports: nothing about the illustrations is in the
# initial DOM, expanding loads them, editing works inside the loaded row, and a
# failed load says so and can be retried.
class Frameworks::LazyExpandedRowSystemTest < ApplicationSystemTestCase
  PLACEHOLDER = "tr[data-matrix-target='expandedRow'][data-loaded='false']"
  LOADED_ROW  = "tr[data-matrix-target='expandedRow'][data-loaded='true']"
  ILLUSTRATION = "Seeks guidance from tech lead"

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, @cap_id, 1,
                                          "Asks clarifying questions")
      handler.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7, eid, rid, 1, ILLUSTRATION)
      handler.publish_version(@framework_id, "test")
    end

    sign_in_as(@admin_user)
  end

  context "edit mode on desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "ship the expanded row as a placeholder with no illustration content" do
      visit edit_framework_path(@framework_id)
      assert_text "Strategic Thinking"

      assert_selector PLACEHOLDER, visible: :all
      assert_no_selector LOADED_ROW, visible: :all
      # The illustration text is nowhere in the document — not even hidden.
      assert_no_text ILLUSTRATION
      assert_no_selector "#illustration-#{@ill_id}", visible: :all
    end

    should "load the illustrations and edit affordances on first expand" do
      visit edit_framework_path(@framework_id)
      assert_text "Strategic Thinking"

      expand_matrix_row("#capability-name-#{@cap_id}")

      assert_text ILLUSTRATION
      assert_selector LOADED_ROW, visible: true
      assert_no_selector PLACEHOLDER, visible: :all
      # Edit-mode content rides along: the "+ Add illustration" affordance and
      # the illustration's own inline editor.
      assert_text "Add illustration"
      assert_selector "#illustration-#{@ill_id} [data-controller='inline-editor']", visible: :all
    end

    should "save an inline illustration edit inside the lazily loaded row" do
      visit edit_framework_path(@framework_id)
      assert_text "Strategic Thinking"

      expand_matrix_row("#capability-name-#{@cap_id}")
      assert_text ILLUSTRATION

      form = start_inline_edit("#illustration-#{@ill_id} li[data-controller='inline-editor']")
      js_fill_in form.find("textarea[name='illustration[description]']"),
                 with: "Proactively seeks guidance from the tech lead"
      # requestSubmit() rather than a button click — see testing.md, "Inline-Editor
      # Form Submits".
      page.execute_script("arguments[0].requestSubmit();", form)

      assert_text "Proactively seeks guidance from the tech lead"
      assert_no_text ILLUSTRATION
    end

    should "show a retryable error when the row fails to load" do
      visit edit_framework_path(@framework_id)
      assert_text "Strategic Thinking"

      # Point the placeholder at a capability the framework doesn't have — the
      # endpoint answers 404 — then restore the real src for the retry.
      good_src = page.evaluate_script(
        "document.querySelector(#{PLACEHOLDER.to_json}).dataset.expandedSrc"
      )
      page.execute_script(<<~JS)
        const row = document.querySelector(#{PLACEHOLDER.to_json});
        row.dataset.expandedSrc = row.dataset.expandedSrc.replace(/[^/]+(\\?.*)?$/, "not-a-capability");
      JS

      expand_matrix_row("#capability-name-#{@cap_id}", await_content: false)

      assert_text "Couldn't load the examples for this capability."
      assert_no_text ILLUSTRATION

      page.execute_script(<<~JS, good_src)
        const row = document.querySelector(#{PLACEHOLDER.to_json});
        row.dataset.expandedSrc = arguments[0];
        row.querySelector("[data-action='matrix#retryExpandedRow']").click();
      JS

      assert_text ILLUSTRATION
      assert_no_text "Couldn't load the examples for this capability."
      assert_selector LOADED_ROW, visible: true
    end
  end

  # View mode lazy-loads too (its expanded rows were 79% of its payload), and
  # it is the mode a narrow viewport can actually operate: edit mode's side
  # panes leave no room for the matrix there (issue #384).
  context "view mode on mobile" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "ship a placeholder and load the illustrations on expand" do
      visit framework_path(@framework_id)
      assert_text "Strategic Thinking"

      assert_selector PLACEHOLDER, visible: :all
      assert_no_text ILLUSTRATION

      expand_matrix_row("#capability-name-#{@cap_id}")

      assert_text ILLUSTRATION
      assert_selector LOADED_ROW, visible: true
      # View mode carries no edit affordances into the loaded row either.
      assert_no_text "Add illustration"
    end
  end
end
