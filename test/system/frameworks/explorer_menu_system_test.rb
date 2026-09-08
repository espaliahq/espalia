# frozen_string_literal: true

require "application_system_test_case"

# The explorer grid's delegated kebab menus and the one hover-cluster rule
# (#380). The grid ships bare triggers; `explorer_menu_controller.js` — mounted
# once on the explorer root — builds the menu on open from the trigger's ids.
#
# What is pinned here is the behaviour that replaced `Kit::Dropdown`: ARIA menu
# semantics, Esc / outside-click closing, keyboard reachability of a
# hover-revealed trigger, and one reveal scope per entity.
class Frameworks::ExplorerMenuSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @rid = rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @cap_id = cap_id = SecureRandom.uuid_v7
      @eid = eid = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1,
                                          "Asks clarifying questions")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "the delegated kebab menu" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
    end

    should "build the menu only on open, with ARIA menu semantics" do
      # Nothing is rendered until the trigger is used — that is the whole point
      # of the delegation (#380).
      assert_no_selector "[data-explorer-menu]", visible: :all
      assert_selector "button[aria-label='Capability actions'][aria-expanded='false']", visible: :all

      open_explorer_menu("Capability actions")

      assert_selector "[data-explorer-menu][role='menu'][aria-orientation='vertical']"
      assert_selector "[data-explorer-menu] [role='menuitem']", minimum: 3
      assert_selector "button[aria-label='Capability actions'][aria-expanded='true']"
    end

    should "close on Esc and hand focus back to the trigger" do
      open_explorer_menu("Capability actions")
      press_escape

      assert_no_selector "[data-explorer-menu]", visible: :all
      assert_selector "button[aria-label='Capability actions'][aria-expanded='false']", visible: :all
      assert_equal "Capability actions",
                   page.evaluate_script("document.activeElement.getAttribute('aria-label')")
    end

    should "close on an outside click" do
      open_explorer_menu("Capability actions")

      page.execute_script(<<~JS)
        document.querySelector("main").dispatchEvent(
          new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
        )
      JS

      assert_no_selector "[data-explorer-menu]", visible: :all
    end

    should "close when a menu item opens a modal" do
      use_explorer_menu("Capability actions", "Discuss…", expect_text: "Start a discussion")

      assert_selector "#request-clarification-modal", visible: true
      assert_no_selector "[data-explorer-menu]", visible: :all
    end

    should "open the shared inline editor from the menu's Edit item" do
      # The kebab lives OUTSIDE the name's Turbo Frame, so the item names the
      # frame and the editor resolves its host from it.
      use_explorer_menu("Capability actions", "Edit name…")

      assert_selector "turbo-frame#capability-name-#{@cap_id} [data-editor-form]", visible: true
    end
  end

  context "the hover cluster" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
    end

    should "reveal the whole row cluster at once when the row is hovered" do
      # Headless Chrome reports `hover: none`, so assert the CSS contract
      # rather than driving a pointer: every control of a scope is hidden until
      # its OWNING entity is hovered or focused, and they share one scope.
      hidden = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("tr[data-hover-cluster='row'] [data-cluster~='row']")]
          .map((el) => getComputedStyle(el).opacity)
      JS
      assert hidden.any?, "the row should carry hover-cluster controls"
      assert hidden.all? { |opacity| opacity.to_f.zero? },
             "every row-cluster control starts hidden, together"

      # An IIFE: evaluate_script wraps its argument in `return (…)`, so a
      # multi-statement body has to be an expression. The reveal transition is
      # frozen first, or the computed opacity read back is a mid-animation value.
      shown = page.evaluate_script(<<~JS)
        (() => {
          const row = document.querySelector("tr[data-hover-cluster='row']");
          const controls = [...row.querySelectorAll("[data-cluster~='row']")];
          controls.forEach((el) => { el.style.transition = "none"; });
          controls[0].focus();
          return controls.map((el) => getComputedStyle(el).opacity);
        })()
      JS
      assert shown.all? { |opacity| opacity.to_f == 1.0 },
             "focusing into the row reveals its whole cluster (keyboard reachability)"
    end

    should "keep a cell's cluster scoped to that cell" do
      # A cell's controls must not pop when the pointer is elsewhere in the row —
      # they answer to the cell's own scope.
      scopes = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("td[data-hover-cluster='cell'] [data-cluster]")]
          .map((el) => el.dataset.cluster.split(" ")[0])
      JS
      assert scopes.any?, "the cell should carry hover-cluster controls"
      assert_equal [ "cell" ], scopes.uniq
    end
  end

  context "at a touch viewport" do
    should "leave the kebab as the cluster's only control" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"

      # `resize_page` alone never flips `pointer: coarse` in headless Chrome, so
      # assert the contract the media query keys off: the kebab is marked as the
      # control that survives, the rest as the ones that collapse into it.
      assert_selector "td[data-hover-cluster='cell'] [data-cluster~='kebab']", visible: :all
      assert_selector "td[data-hover-cluster='cell'] [data-cluster~='inline']", visible: :all
      # …and everything the collapsing controls do is reachable from the kebab.
      open_explorer_menu("Expectation actions")
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Edit expectation…"
      assert_selector "[data-explorer-menu] [role='menuitem']", text: "Discuss…"
    end
  end
end
