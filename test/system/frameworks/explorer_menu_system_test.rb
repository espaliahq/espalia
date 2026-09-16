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
      # Two more rows below the first, so a menu opened on row 1 overlaps them —
      # the arrangement the sticky-column paint-order bug needs (§11a).
      2.times do |index|
        other = SecureRandom.uuid_v7
        handler.add_capability(@framework_id, other, SecureRandom.uuid_v7, cat_id, "Filler #{index}")
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, other, rid)
        handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                            other, 1, "Filler expectation #{index}")
      end
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

    # A `position: fixed` menu still composites inside the nearest stacking
    # context, and the sticky capability column is `z-[2]` — so without the
    # lift the next row's equally-ranked sticky cell paints over the menu's
    # lower items (#380 visual pass).
    should "paint over the rows beneath it, not under the next sticky cell" do
      open_explorer_menu("Capability actions")

      # Probe where the overlap actually is: the menu overhangs the sticky
      # column into the level columns, and only the part still over a LATER
      # row's sticky cell is at risk — a centre-only probe misses the bug. The
      # script reports the overlap it found so a fixture with no overlap fails
      # loudly instead of passing vacuously.
      probe = page.evaluate_script(<<~JS)
        (() => {
          const menu = document.querySelector("[data-explorer-menu]");
          const box = menu.getBoundingClientRect();
          const cells = [...document.querySelectorAll("tr[data-hover-cluster='row'] td.sticky")]
            .filter((cell) => !menu.contains(cell) && !cell.contains(menu));
          for (const cell of cells) {
            const r = cell.getBoundingClientRect();
            const x = Math.max(box.left, r.left) + 2;
            const y = Math.max(box.top, r.top) + 2;
            if (x >= Math.min(box.right, r.right) || y >= Math.min(box.bottom, r.bottom)) continue;

            const hit = document.elementFromPoint(x, y);
            return { overlapped: true, inMenu: Boolean(hit && hit.closest("[data-explorer-menu]")) };
          }
          return { overlapped: false, inMenu: false };
        })()
      JS

      assert probe["overlapped"],
             "fixture problem: no later sticky cell overlaps the open menu, so nothing is proved"
      assert probe["inMenu"],
             "the menu must paint over a later row's sticky cell, not under it"
    end

    should "restore the lifted stacking context when the menu closes" do
      column = "tr[data-hover-cluster='row'] td.sticky"
      before = page.evaluate_script("getComputedStyle(document.querySelector(arguments[0])).zIndex",
                                    column)
      open_explorer_menu("Capability actions")
      press_escape

      assert_no_selector "[data-explorer-menu]", visible: :all
      assert_equal before,
                   page.evaluate_script(
                     "getComputedStyle(document.querySelector(arguments[0])).zIndex", column
                   )
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

    should "hang the role tree's rename pencil off the tree row, not the name span" do
      # A tree row already reveals the family's edit dialog and the role's ⋮ on
      # row hover; the pencil must appear at the same moment, not when the
      # pointer happens to be over the name (§11a).
      owners = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("[data-tree-target='role'] [data-cluster~='tree']")]
          .map((el) => el.closest("[data-hover-cluster]").dataset.treeTarget || "")
      JS
      assert owners.any?, "the tree row should carry a cluster control"
      assert_equal [ "role" ], owners.uniq
    end

    # The coarse-pointer rule hides `inline` controls; a cluster with no kebab
    # would simply lose them. Every cluster is checked, not a sampled one —
    # this is the guard for the whole vocabulary, and `resize_to` can't flip
    # `pointer: coarse` so no viewport test would catch a violation.
    should "give every collapsing control a kebab to collapse into" do
      orphans = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("[data-hover-cluster]")]
          .filter((owner) => {
            const scope = owner.dataset.hoverCluster;
            const has = (kind) => owner.querySelector(`[data-cluster~="${scope}"][data-cluster~="${kind}"]`);
            return has("inline") && !has("kebab");
          })
          .map((owner) => owner.dataset.hoverCluster)
      JS

      assert_empty orphans,
                   "a cluster hides its inline controls on a coarse pointer, so it must " \
                   "carry a kebab that offers the same actions (see CONTROL_KINDS)"
    end

    should "size every cluster glyph, whether the control sizes it or the call site does" do
      # #383 moved the sizing of the grid's glyphs onto the control that holds
      # them (`.explorer-kebab > svg`), so those call sites pass no class. A
      # control OUTSIDE that family — the role tree's Kit::Dropdown kebab — has
      # no such rule and must keep its own; dropping its class there rendered a
      # default-sized SVG that swallowed the tree row, and no unit test could
      # see it (the sizes live in CSS).
      sizes = page.evaluate_script(<<~JS)
        (() => {
          const read = (selector) => {
            const svg = document.querySelector(selector);
            if (!svg) return null;
            const box = svg.getBoundingClientRect();
            return [ Math.round(box.width), Math.round(box.height) ];
          };
          return {
            kebab: read("button.explorer-kebab svg"),
            discuss: read("button.explorer-discuss svg"),
            pencil: read("button.explorer-cluster-btn svg"),
            add: read("button.explorer-add svg"),
            tree: read("[data-tree-target='role'] [aria-haspopup='true'] svg")
          };
        })()
      JS

      sizes.each do |name, box|
        assert box, "expected a #{name} glyph in the edit-mode grid"
        width, height = box
        assert_equal width, height, "#{name} glyph should be square, got #{width}x#{height}"
        assert_includes 10..20, width,
                        "#{name} glyph is #{width}px — an unsized <svg> renders far larger"
      end
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

  # One add treatment: a dashed ghost, always visible, anchored where the thing
  # it adds will land (§11a).
  context "the add affordances" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
    end

    should "keep the add-capability label in the capability column, not centred across the table" do
      # Its label must be readable at the default horizontal scroll — a
      # colspan-ed row centres it somewhere off to the right (#380 visual pass).
      label = find("button.explorer-add", text: "Add capability", match: :first)
      column = find("th, td", text: "CAPABILITY", match: :first)

      assert label.rect.x < column.rect.x + column.rect.width,
             "the add-capability affordance must sit inside the capability column"
      assert label.rect.width < column.rect.width + 40,
             "the add-capability affordance must not span the whole table"
    end

    should "render every add affordance in the one dashed-ghost treatment" do
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Add example"

      [ "Add capability", "Add example" ].each do |label|
        assert_selector "button.explorer-add", text: label
      end
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
