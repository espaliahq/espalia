# frozen_string_literal: true

require "application_system_test_case"

# Pins the matrix's sticky geometry: an expanding row must land BELOW the
# sticky stack (matrix header + category band), whatever height that stack
# happens to be.
#
# The offsets used to be constants — `scroll-mt-20` (80 px) on the compact row
# and `top-[41px]` on the category band — both sized for the one-line
# code-badge header. In edit mode with <= 3 roles the header renders full level
# titles (each with a rename pencil) and measures ~113 px, so the capability
# name and its kebab landed underneath it: a real pointer click on the kebab
# hit the sticky `<th>`, and only a JS-dispatched click opened the menu
# (issue #382). `matrix_controller` now MEASURES both heights and publishes
# them as `--matrix-header-h` / `--matrix-category-h`.
#
# The role counts below are the two header shapes: 1 and 3 roles render full
# level titles (tall), 11 collapses to compact code badges (short).
class Frameworks::MatrixStickyOffsetsSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  ROLE_COUNT = 11
  LEVEL_COUNT = 3
  # The row under test must be able to reach the TOP of the scrollport, or
  # `scrollIntoView({ block: "start" })` runs out of scroll and parks it
  # harmlessly mid-pane — which is how a first cut of this test passed against
  # the very geometry it exists to catch. So: enough rows below the target that
  # a full top-alignment is satisfiable (`maxedOut` is asserted false), and
  # enough above it that the expand scrolls at all (`scrolled` is asserted > 0).
  CAPABILITY_COUNT = 30
  TARGET_ROW_INDEX = 5

  # Everything the sticky assertions need, read in one round trip: where the
  # capability's name line sits, where the sticky stack ends, and — the same
  # question a real pointer click asks — what is actually on top at the name's
  # and the kebab's own coordinates.
  GEOMETRY_PROBE_JS = <<~JS
    (() => {
      const row = document.querySelector(arguments[0]);
      if (!row) return null;

      // The sticky boxes are the header CELLS and the band's own <tr> — a
      // `<thead>` reports its normal-flow position, hundreds of pixels off
      // once the grid is scrolled.
      const headerCell = document.querySelector("thead th");
      const band = row.closest("tbody")
        .querySelector("tr[data-matrix-target='categoryHeader']");
      const line = row.querySelector(".mx-line");
      const kebab = row.querySelector("button[aria-label='Capability actions']");
      if (!headerCell || !line) return null;

      const stackBottom = Math.max(
        headerCell.getBoundingClientRect().bottom,
        band ? band.getBoundingClientRect().bottom : 0
      );
      const topmostAt = (rect) => {
        const el = document.elementFromPoint(
          Math.round(rect.left + Math.min(rect.width / 2, 24)),
          Math.round(rect.top + rect.height / 2)
        );
        if (!el) return "nothing";
        if (row.contains(el)) return "row";
        // Name what actually answered, so a failure points at the covering
        // element rather than at a bare tag name.
        const closestId = el.closest("[id]");
        return el.tagName.toLowerCase() + (closestId ? ` in #${closestId.id}` : "");
      };

      const container = document.querySelector("[data-matrix-target='scrollContainer']");
      const maxScroll = container ? container.scrollHeight - container.clientHeight : 0;
      return {
        headerHeight: Math.round(headerCell.getBoundingClientRect().height),
        maxedOut: container ? Math.abs(container.scrollTop - maxScroll) < 2 : true,
        nameTop: Math.round(line.getBoundingClientRect().top),
        stackBottom: Math.round(stackBottom),
        onTopOfName: topmostAt(line.getBoundingClientRect()),
        onTopOfKebab: kebab ? topmostAt(kebab.getBoundingClientRect()) : "missing",
        scrolled: container ? Math.round(container.scrollTop) : 0
      };
    })()
  JS

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Sticky Offsets Framework")

      # ~150 commands: one batch, one aggregate load, one snapshot write.
      handler.batch(@framework_id) { seed_framework(handler) }
      handler.publish_version(@framework_id, "test")
    end

    sign_in_as(@admin_user)
  end

  # Both header shapes × both viewports, in one test each: the geometry probe
  # and the real pointer click are two readings of the same landing.
  [
    { name: "desktop", size: DESKTOP_SIZE },
    { name: "mobile", size: MOBILE_SIZE }
  ].each do |viewport|
    [ 1, 3, ROLE_COUNT ].each do |role_count|
      context "with #{role_count} role(s) selected in edit mode on #{viewport[:name]}" do
        setup do
          page.driver.browser.manage.window.resize_to(*viewport[:size])
          visit edit_framework_path(@framework_id, roles: @role_ids.first(role_count))
          assert_text "Edit mode"
          close_context_pane if viewport[:name] == "mobile"
        end

        should "land the expanded row's name and kebab clear of the sticky stack, clickable" do
          expand_matrix_row(target_row_selector)

          geometry = settled_geometry

          assert_operator geometry["scrolled"], :>, 0,
                          "the expand did not scroll — nothing was at risk of hiding under the header"
          assert_equal false, geometry["maxedOut"],
                       "the grid ran out of scroll, so the row could not be aligned to the top — " \
                       "the arrangement, not the geometry, is what would be under test"
          assert_operator geometry["nameTop"], :>=, geometry["stackBottom"],
                          "the capability name sits #{geometry['stackBottom'] - geometry['nameTop']}px " \
                          "under the sticky stack (header measured #{geometry['headerHeight']}px)"
          assert_equal "row", geometry["onTopOfName"],
                       "a click at the capability name would land on <#{geometry['onTopOfName']}>"
          assert_equal "row", geometry["onTopOfKebab"],
                       "a click at the row kebab would land on <#{geometry['onTopOfKebab']}>"

          click_row_kebab_for_real

          assert_selector "[data-explorer-menu][role='menu']"
        end
      end
    end
  end

  # Header height varies with the role selection, not the viewport, so this
  # sweeps the shapes at one size.
  context "the category band, at every header height" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    [ 1, 3, ROLE_COUNT ].each do |role_count|
      should "stick immediately below the matrix header with #{role_count} role(s)" do
        visit edit_framework_path(@framework_id, roles: @role_ids.first(role_count))
        assert_text "Edit mode"

        gap = page.evaluate_script(<<~JS)
          (() => {
            const container = document.querySelector("[data-matrix-target='scrollContainer']");
            container.scrollTop = 400;
            const headerCell = document.querySelector("thead th");
            const band = document.querySelector("tr[data-matrix-target='categoryHeader']");
            return Math.round(
              band.getBoundingClientRect().top - headerCell.getBoundingClientRect().bottom
            );
          })()
        JS

        # Flush against the header: never negative (sliding underneath is the
        # `top-[41px]` bug) and never floating free of it.
        assert_operator gap, :>=, 0, "the category band is #{-gap}px under the matrix header"
        assert_operator gap, :<=, 2, "the category band floats #{gap}px below the matrix header"
      end
    end
  end

  # The variables describe the grid on screen. A search that filters every
  # capability out leaves no table to measure, and keeping the last grid's
  # numbers makes them mean "the most recent non-empty render" instead.
  context "when a search leaves no grid to measure" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit edit_framework_path(@framework_id, roles: @role_ids.first(1))
      assert_text "Edit mode"
    end

    should "drop the measured sticky variables, falling back to the CSS defaults" do
      assert_operator measured_sticky_variables.compact_blank.size, :==, 2,
                      "expected both variables to be measured before the search"

      # By selector, not by label: the filter box carries an `aria-label` and no
      # `<label>`/name/id, and Capybara's field locator does not read ARIA.
      js_fill_in "[data-framework-search-target='input']", with: "zzz-matches-nothing"
      assert_text "No capabilities match"

      assert_empty measured_sticky_variables.compact_blank,
                   "the previous grid's spacing outlived the grid it described"
    end
  end

  private

  def measured_sticky_variables
    page.evaluate_script(<<~JS)
      (() => {
        const root = document.querySelector("[data-controller~='matrix']");
        return [ "--matrix-header-h", "--matrix-category-h" ]
          .map((name) => root.style.getPropertyValue(name).trim());
      })()
    JS
  end

  def seed_framework(handler)
    family_id = SecureRandom.uuid_v7
    handler.add_role_family(@framework_id, family_id, "Engineering", department: "Technology")

    @role_ids = Array.new(ROLE_COUNT) do |index|
      role_id = SecureRandom.uuid_v7
      handler.add_role(@framework_id, role_id, family_id,
                       "Software Engineer #{index + 1}", "E#{index + 1}", "ic")
      LEVEL_COUNT.times do |level|
        handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, level + 1,
                          "Engineer grade #{level + 1}", "E#{index + 1}L#{level + 1}",
                          is_entry: level.zero?)
      end
      role_id
    end

    category_id = SecureRandom.uuid_v7
    handler.add_capability_category(@framework_id, category_id, "Thinking", ordinal: 1,
                                    description: "How we reason about problems")

    @capability_ids = Array.new(CAPABILITY_COUNT) do |index|
      seed_capability(handler, category_id, index)
    end
  end

  def seed_capability(handler, category_id, index)
    cap_id = SecureRandom.uuid_v7
    handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, category_id,
                           "Capability #{index + 1}")
    # The first role only: every selection under test starts from it, so one
    # binding keeps all CAPABILITY_COUNT rows in scope for 1, 3 and 11 roles
    # without paying for CAPABILITY_COUNT x ROLE_COUNT binding events.
    handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id,
                                           @role_ids.first)
    LEVEL_COUNT.times do |level|
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cap_id, level + 1,
        "Anticipates downstream effects at level #{level + 1}"
      )
    end
    cap_id
  end

  # The ONE place a real pointer click is the behaviour under test: a
  # JS-dispatched click bypasses hit testing entirely, so it cannot see the row
  # sitting under the sticky header — which is the bug (#382). The hover comes
  # first because the kebab is `opacity: 0` until its cluster is revealed, and
  # Selenium refuses to click an element it considers not displayed.
  def click_row_kebab_for_real
    row = find(target_row_selector)
    row.hover
    # rubocop:disable SystemTests/FlakeProneClick
    row.find("button[aria-label='Capability actions']").click
    # rubocop:enable SystemTests/FlakeProneClick
  end

  # At 375 px the activity pane is a fixed `w-80` flex sibling, so the grid is
  # left a ~40 px sliver and every probe lands in the pane instead of the row.
  # That layout is issue #384's (edit mode on mobile); the sticky geometry this
  # test owns is vertical, so close the pane — as a phone user would — and
  # measure the grid.
  def close_context_pane
    wait_for_stimulus "framework-explorer"
    page.execute_script(<<~JS)
      document.querySelector("[data-framework-explorer-target='contextPaneToggle']").click();
    JS
    assert_no_selector "[data-framework-explorer-target='contextPane']", visible: true
  end

  # A row with rows both above it (so expanding scrolls) and enough below it
  # (so the scroll can actually put it at the top of the scrollport).
  def target_row_selector
    "#capability-row-#{@capability_ids[TARGET_ROW_INDEX]}"
  end

  # The expand kicks off a smooth scroll and, once it settles, a guard pass that
  # nudges the row out from under the stack. Poll until the geometry stops
  # moving rather than guessing at a duration.
  def settled_geometry
    deadline = Time.current + Capybara.default_max_wait_time
    previous = nil
    geometry = nil

    loop do
      geometry = page.evaluate_script(GEOMETRY_PROBE_JS, target_row_selector)
      return geometry if geometry && geometry == previous && geometry["scrolled"].positive?
      break if Time.current > deadline

      previous = geometry
      sleep 0.15
    end

    geometry
  end
end
