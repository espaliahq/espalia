# frozen_string_literal: true

require "application_system_test_case"

# Pins the sticky column's opacity invariant: every sticky cell in the matrix
# must fully mask what scrolls underneath it.
#
# `position: sticky` does no clipping — the cell's own background is the only
# thing hiding the scrolled content. A translucent background therefore reads
# as a hole, which is how a whole column of illustration text ended up
# rendering under the capability name (issue #371). See framework-explorer.md
# → "Sticky Positioning" and Hard-Won Lesson 24.
class Frameworks::MatrixStickyColumnSystemTest < ApplicationSystemTestCase
  # Enough level columns (min-w-[180px] each) that the matrix is wider than the
  # pane at desktop width — without horizontal overflow there is nothing to
  # scroll and the test would pass vacuously. `scrollLeft` is asserted below so
  # this stays honest if the layout changes.
  LEVEL_COUNT = 8

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      handler = Frameworks::CommandHandler.new
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user)

      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Sticky Column Framework")

      family_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, family_id, "Software Engineering", department: "Engineering")
      handler.add_role(@framework_id, role_id, family_id, "Software Engineer", "E", "ic")
      LEVEL_COUNT.times do |i|
        handler.add_level(
          @framework_id, SecureRandom.uuid_v7, role_id, i + 1,
          "Engineer #{i + 1}", "E#{i + 1}", is_entry: i.zero?
        )
      end

      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, role_id)

      # An expectation at every level, each with a long illustration — the
      # content that bled through the sticky gutter in the original report.
      LEVEL_COUNT.times do |i|
        eid = SecureRandom.uuid_v7
        handler.set_behavioural_expectation(
          @framework_id, eid, SecureRandom.uuid_v7, cap_id, i + 1,
          "Anticipates downstream effects and adapts thinking to align with business goals"
        )
        handler.add_role_illustration(
          @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, eid, role_id, i + 1,
          "Reviews technical requirements and reworks the approach with the wider team"
        )
      end

      handler.publish_version(@framework_id, "test")
    end

    sign_in_as(@user)
  end

  # True when the CSS colour is fully opaque.
  #
  # Compositing it over black and over white gives the same pixel only when
  # nothing shows through. Deliberately syntax-agnostic: computed backgrounds
  # here come back as `rgb(...)`, `oklab(... / 0.3)` or `color-mix(...)`
  # depending on the utility, and a regex over those would be a second bug
  # waiting to happen.
  OPACITY_PROBE_JS = <<~JS
    (color) => {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      const ctx = canvas.getContext("2d", { willReadFrequently: true });
      const over = (base) => {
        ctx.fillStyle = base;
        ctx.fillRect(0, 0, 1, 1);
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, 1, 1);
        return Array.from(ctx.getImageData(0, 0, 1, 1).data).join(",");
      };
      return over("#000000") === over("#ffffff");
    }
  JS

  context "with the matrix scrolled horizontally and a row expanded" do
    should "paint every sticky cell fully opaque so nothing bleeds through" do
      visit framework_path(@framework_id)
      expand_matrix_row("tr[data-matrix-target='row']")

      result = page.evaluate_script(<<~JS)
        (() => {
          const isOpaque = #{OPACITY_PROBE_JS};

          const scroller = document.querySelector("[data-matrix-target='scrollContainer']");
          scroller.scrollLeft = scroller.scrollWidth;

          const cells = {
            expanded: "tr[data-matrix-target='expandedRow'] td.sticky",
            compact: "tr[data-matrix-target='row'] td.sticky",
            categoryHeader: "tr[data-matrix-target='categoryHeader'] td",
            headerCorner: "thead th.sticky.left-0"
          };

          const opacity = {};
          const colors = {};
          for (const [name, selector] of Object.entries(cells)) {
            const el = document.querySelector(selector);
            if (!el) { opacity[name] = "missing"; continue; }
            const bg = getComputedStyle(el).backgroundColor;
            colors[name] = bg;
            opacity[name] = isOpaque(bg);
          }
          return { scrollLeft: scroller.scrollLeft, opacity, colors };
        })()
      JS

      # Without real horizontal overflow there is nothing to bleed through and
      # the assertions below would pass vacuously.
      assert_operator result["scrollLeft"], :>, 0,
                      "matrix did not scroll horizontally — fixture is no longer wide enough"

      result["opacity"].each do |name, opaque|
        assert_equal true, opaque,
                     "#{name} sticky cell is not opaque (#{result["colors"][name]}) — " \
                     "scrolled content will render through it"
      end
    end

    should "declare no translucent background on any sticky cell, hover included" do
      visit framework_path(@framework_id)
      expand_matrix_row("tr[data-matrix-target='row']")

      # The computed check above only sees the resting state. A `/NN` alpha
      # hiding in a hover or dark variant bleeds only while hovering, or only
      # in dark mode — which is exactly how `dark:group-hover:bg-gray-800/50`
      # survived on the compact row. Read the class lists instead so every
      # variant is covered.
      translucent = page.evaluate_script(<<~JS)
        (() => {
          const offenders = [];
          for (const el of document.querySelectorAll("table .sticky, table .sticky *")) {
            if (!el.classList) continue;
            for (const token of el.classList) {
              // e.g. bg-gray-800/50, dark:group-hover:bg-blue-900/10
              if (/(^|:)bg-[a-z]+-\\d+\\/\\d+$/.test(token)) offenders.push(token);
            }
          }
          return [ ...new Set(offenders) ];
        })()
      JS

      assert_empty translucent,
                   "translucent background(s) on a sticky matrix cell: #{translucent.inspect} — " \
                   "use the opaque composite instead (framework-explorer.md, Hard-Won Lesson 24)"
    end
  end
end
