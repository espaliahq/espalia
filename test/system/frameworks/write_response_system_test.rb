# frozen_string_literal: true

require "application_system_test_case"

# The explorer's ONE write-response contract (#381): every edit-mode write
# answers a Turbo Stream touching just the rows it changed, plus one toast.
#
# The load-bearing assertion in every test here is `assert_page_not_reloaded` —
# a marker set on `window` before the action, which only survives if the document
# was never replaced. Without it these tests would pass just as happily against
# the old full-page redirect (testing.md: an assertion a dropped click would
# also satisfy is not a test), which is exactly what they exist to prevent
# coming back.
class Frameworks::WriteResponseSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze
  TOAST = "#framework-write-status"

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = FactoryBot.create(:person, tenant: @tenant, email: @admin_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                                      person: @admin_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @other_cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Engineer I", "E1",
                        is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 2, "Engineer II", "E2")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id,
                             "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, @role_id)
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, @cap_id, 1,
                                          "Asks clarifying questions")
      @illustration_id = SecureRandom.uuid_v7
      handler.add_role_illustration(@framework_id, @illustration_id, SecureRandom.uuid_v7,
                                    eid, @role_id, 1, "Seeks guidance from tech lead")

      # A second row, so a reorder has a neighbour to move against and an
      # unrelated open expanded row has somewhere to survive.
      handler.add_capability(@framework_id, @other_cap_id, SecureRandom.uuid_v7, @cat_id,
                             "Delivery Focus")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7,
                                             @other_cap_id, @role_id)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7,
                                          SecureRandom.uuid_v7, @other_cap_id, 1, "Ships work")

      handler.publish_version(@framework_id, "test")
    end
  end

  # Stamps a marker on `window`. A full page load replaces the document (and the
  # marker with it), so its survival is the proof the write stayed in-page.
  def mark_page
    page.execute_script("window.__writeResponseMarker = true")
  end

  def assert_page_not_reloaded
    assert page.evaluate_script("window.__writeResponseMarker === true"),
           "the write reloaded the page — it must answer a Turbo Stream (#381)"
  end

  def visit_edit(size: DESKTOP_SIZE)
    page.driver.browser.manage.window.resize_to(*size)
    sign_in_as(@admin_user)
    visit edit_framework_path(@framework_id)
    wait_for_stimulus "matrix"
  end

  context "adding a capability" do
    should "insert the row in place, toast, and open the draft without reloading" do
      visit_edit
      # An expanded row open elsewhere is the thing a full reload used to cost.
      expand_matrix_row("tr[data-capability-id='#{@cap_id}']")
      assert_text "Seeks guidance from tech lead"
      mark_page

      page.execute_script(
        "document.querySelector(\"button[data-modal-target-id='add-capability-modal']\").click();"
      )
      assert_selector "#add-capability-modal", visible: true
      js_fill_in "add_capability_name", with: "Systems Design"
      page.execute_script(<<~JS, @role_id)
        document.querySelector(`#add-capability-modal input[value='${arguments[0]}']`).click();
      JS
      # By CSS selector, not label: the grid's own "+ Add capability" ghost
      # carries the same text, so a locator-based click is ambiguous.
      click_selector_with_js_fallback("#add-capability-modal button[type='submit']",
                                      expect_text: "Added “Systems Design”.")

      assert_page_not_reloaded
      assert_selector "tr[data-capability-id]", text: "Systems Design"
      # The open expanded row is untouched, and the draft pill arrived with the
      # same response.
      assert_text "Seeks guidance from tech lead"
      assert_text "v2 draft"
    end
  end

  context "authoring an expectation" do
    should "replace only that cell, toast, and keep the page" do
      visit_edit
      mark_page

      form = start_inline_edit(find("[data-editor-submit-label='Add']", match: :first))
      submit_inline_edit(form, with: "Identifies root causes")

      assert_selector TOAST, text: "Added an expectation."
      assert_page_not_reloaded
      assert_text "Identifies root causes"
    end
  end

  context "archiving an illustration" do
    should "use the shared modal (not a native confirm) and remove the frame in place" do
      visit_edit
      expand_matrix_row("tr[data-capability-id='#{@cap_id}']")
      assert_text "Seeks guidance from tech lead"
      mark_page

      use_explorer_menu("Example actions", "Archive",
                        scope: "li[data-editor-action*='/illustrations/']")
      assert_selector "#archive-illustration-modal", visible: true
      click_button_with_js_fallback("Archive example", expect_text: "Archived the example.")

      assert_page_not_reloaded
      # Gone from the still-expanded row — no re-expansion needed, which is the
      # whole difference from the old confirm-then-reload flow.
      assert_no_text "Seeks guidance from tech lead"
    end
  end

  context "reordering a capability" do
    should "move the rows in place without re-fetching the matrix" do
      visit_edit
      expand_matrix_row("tr[data-capability-id='#{@other_cap_id}']")
      assert_text "Ships work"
      mark_page

      # "Delivery Focus" is the second row; move it above "Strategic Thinking".
      use_explorer_menu("Capability actions", "Move up",
                        scope: "tr[data-capability-id='#{@other_cap_id}']")

      assert_selector TOAST, text: "Moved “Delivery Focus”."
      assert_page_not_reloaded
      assert_equal [ @other_cap_id, @cap_id ], rendered_capability_order
      # The row it moved kept its loaded expanded row — a matrix re-fetch would
      # have thrown it away (Hard-Won Lesson 23).
      assert_selector "#expanded-row-#{@other_cap_id}:not([data-loaded='false'])", visible: :all
    end

    should "offer the reversed directions after an in-place move" do
      visit_edit
      use_explorer_menu("Capability actions", "Move up",
                        scope: "tr[data-capability-id='#{@other_cap_id}']")
      assert_selector TOAST, text: "Moved"

      # The neighbours are re-read from the DOM on every open, so the row that
      # is now first offers only "Move down" — a server-sent neighbour id would
      # still be pointing at the pre-move order here.
      open_explorer_menu("Capability actions",
                         scope: "tr[data-capability-id='#{@other_cap_id}']")
      # Present-first: assert_no_selector returns the moment nothing matches, so
      # asserting the absence first could pass against a menu that hasn't
      # rendered its items yet and would never catch a re-added "Move up".
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Move down"
      assert_no_selector "[data-explorer-menu] [role='menuitem']", text: "Move up"
    end
  end

  context "on a mobile viewport" do
    should "still write in place and show the toast" do
      visit_edit(size: MOBILE_SIZE)
      mark_page

      form = start_inline_edit(find("[data-editor-submit-label='Add']", match: :first))
      submit_inline_edit(form, with: "Identifies root causes")

      assert_selector TOAST, text: "Added an expectation."
      assert_page_not_reloaded
    end
  end

  # The capability ids of the rendered compact rows, in DOM order.
  def rendered_capability_order
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll("tr[data-capability-id][data-movable='true']")]
        .map((row) => row.dataset.capabilityId)
    JS
  end
end
