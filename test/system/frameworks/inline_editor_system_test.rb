# frozen_string_literal: true

require "application_system_test_case"

# The explorer's ONE shared inline editor (#379): keyboard ergonomics, honest
# Save-vs-Propose labelling, surfaced save failures that keep the typed text,
# and the unsaved-change guard on a matrix re-fetch.
class Frameworks::InlineEditorSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @contributor_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      contributor = FactoryBot.create(:person, tenant: @tenant, email: @contributor_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @contributor_user,
                                      role: :member, person: contributor)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          @cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "test")

      # A collaborator with suggest rights but no approval tier anywhere.
      FactoryBot.create(:framework_collaborator, tenant: @tenant,
                        framework_id: @framework_id, person_id: contributor.id, role: "collaborator")
    end
  end

  # The capability-name editor host in the sticky left column.
  def capability_name_host
    find("turbo-frame#capability-name-#{@cap_id} > div")
  end

  # A role checkbox re-fetches the whole matrix — the guarded path.
  def toggle_first_role
    page.execute_script(
      "document.querySelector(\"input[data-action*='tree#toggleRole']\").click();"
    )
  end

  # The editor binds Esc / Cmd+Enter on the textarea itself, so dispatch the
  # KeyboardEvent there — Selenium's key dispatch needs an interactable target
  # and drops keys on starved CI (testing.md, press_escape).
  def press_key(element, key, ctrl: false)
    page.execute_script(<<~JS, element, key, ctrl)
      const [el, key, ctrlKey] = [arguments[0], arguments[1], arguments[2]]
      el.dispatchEvent(new KeyboardEvent("keydown", {
        key: key, ctrlKey: ctrlKey, bubbles: true, cancelable: true
      }))
    JS
  end

  context "hit areas" do
    # Save and Cancel sit 10px under the textarea, exactly as far as an xs
    # button's 44px hit area reaches, so a pixel less would let a click on
    # the textarea's edge submit the edit.
    should "leave the textarea's edge to the textarea" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      form = start_inline_edit(capability_name_host)
      assert form.has_selector?("textarea[data-editor-input]")

      assert_no_stolen_taps
    end
  end

  context "keyboard ergonomics" do
    should "cancel on Esc and save on Cmd/Ctrl+Enter" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      form = start_inline_edit(capability_name_host)
      input = form.find("[data-editor-input]")
      js_fill_in input, with: "Abandoned edit"
      press_key(input, "Escape")

      assert_no_selector "[data-editor-form]"
      assert_text "Strategic Thinking"

      form = start_inline_edit(capability_name_host)
      input = form.find("[data-editor-input]")
      js_fill_in input, with: "Sharper Strategic Thinking"
      press_key(input, "Enter", ctrl: true)

      assert_text "Sharper Strategic Thinking"
    end

    should "grow the textarea with its content instead of scrolling a fixed box" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      form = start_inline_edit(capability_name_host)
      input = form.find("[data-editor-input]")
      height_before = input.evaluate_script("this.getBoundingClientRect().height")
      js_fill_in input, with: ([ "A long line of framework prose." ] * 12).join(" ")

      assert_operator input.evaluate_script("this.getBoundingClientRect().height"),
                      :>, height_before
    end
  end

  context "Save vs Propose" do
    should "say Save for an approver in editing mode" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      form = start_inline_edit(capability_name_host)
      assert_equal "Save", form.find("[data-editor-submit]").text
    end

    should "flip to Propose the moment the header toggle moves, with no reload" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "edit-mode-toggle"

      form = start_inline_edit(capability_name_host)
      assert_equal "Save", form.find("[data-editor-submit]").text

      page.execute_script(
        "document.querySelector(\"button[data-edit-mode-toggle-target='suggestingButton']\").click();"
      )
      assert_selector "[data-editor-submit]", text: "Propose"
    end

    should "say Propose for a contributor with no approval tier, and lock the toggle" do
      sign_in_as(@contributor_user)
      visit edit_framework_path(@framework_id)

      # A viewer who clears no tier can never be "editing" — the choice is
      # replaced by a static label rather than a toggle that does nothing.
      assert_no_selector "[data-controller='edit-mode-toggle']"
      assert_text "Suggesting"

      form = start_inline_edit(capability_name_host)
      assert_equal "Propose", form.find("[data-editor-submit]").text
    end
  end

  context "save failures" do
    should "show an inline error in the cell and keep the typed text" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      form = start_inline_edit(capability_name_host)
      # A blank value can't become a suggestion — the server rejects it.
      submit_inline_edit(form, with: "   ")

      assert_text "Couldn’t save:"
      # The editor re-opens on the rejected host, seeded with the attempt —
      # a bodyless 422 (the old behaviour) showed nothing at all.
      assert_selector "[data-editor-form]", visible: true
      assert_equal "   ", find("[data-editor-input]").value
      assert_text "Strategic Thinking"
    end

    should "clear the error when the rejected edit is abandoned" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)

      submit_inline_edit(start_inline_edit(capability_name_host), with: "   ")
      assert_text "Couldn’t save:"

      cancel_inline_edit(find("[data-editor-form]"))

      # Otherwise the cell keeps a permanent-looking alert until the next full
      # matrix render (found in the Chrome MCP pass).
      assert_no_text "Couldn’t save:"
      assert_no_selector "[data-editor-error]", visible: :all
      assert_text "Strategic Thinking"
    end
  end

  context "unsaved-change guard" do
    should "ask before a matrix re-fetch throws an open editor away" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      form = start_inline_edit(capability_name_host)
      js_fill_in form.find("[data-editor-input]"), with: "Work in progress"

      # A role toggle re-fetches the whole matrix, which would silently discard
      # the editor. Decline the prompt and the edit survives. Stub confirm
      # rather than using dismiss_confirm — a modal handler registered around a
      # JS-dispatched click races on starved CI (testing.md, auto_confirm).
      page.execute_script("window.confirm = () => false;")
      toggle_first_role

      assert_selector "[data-editor-form]", visible: true
      assert_equal "Work in progress", find("[data-editor-input]").value
    end

    should "let go of the editor once the discard is accepted, and not re-prompt" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      form = start_inline_edit(capability_name_host)
      js_fill_in form.find("[data-editor-input]"), with: "Work in progress"

      page.execute_script("window.__confirms = 0; window.confirm = () => { window.__confirms++; return true };")
      toggle_first_role
      assert_no_selector "[data-editor-form]"
      # The dirty flag must not outlive the frame swap, or every later filter
      # change re-prompts with nothing to discard.
      assert_no_selector "[data-editor-dirty='true']", visible: :all

      toggle_first_role
      assert_equal 1, page.evaluate_script("window.__confirms")
    end
  end

  context "mobile viewport" do
    should "open the editor without widening the matrix table" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      table = find("#framework-matrix table")
      width_before = table.evaluate_script("this.getBoundingClientRect().width")

      start_inline_edit(capability_name_host)

      assert_in_delta width_before,
                      table.evaluate_script("this.getBoundingClientRect().width"), 1.0
    end
  end
end
