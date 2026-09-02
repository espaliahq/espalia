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

  # Floor for the class-list scan's reach. The fixture renders one sticky
  # corner th, LEVEL_COUNT sticky column ths, and two sticky tds (compact +
  # expanded) — well above this. The floor exists so a selector that stops
  # matching (stickiness moved behind a component class, frame failed to
  # render) fails loudly instead of scanning nothing and reporting "clean".
  MIN_STICKY_CELLS = 4

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

  # Reports whether a CSS colour is fully opaque, or that it could not be read.
  #
  # Compositing over black and over white gives the same pixel only when
  # nothing shows through. Deliberately syntax-agnostic: computed backgrounds
  # arrive as `rgb(...)`, `oklab(... / 0.3)` or `color-mix(...)` depending on
  # the utility, and a regex over those would be a second bug waiting to happen.
  #
  # Canvas is stricter than CSS, though — assigning an unparseable colour to
  # `fillStyle` is a SILENT no-op, which would leave the previous colour in
  # place and report a genuinely opaque cell as translucent, sending the reader
  # to fix an app that is fine. Two sentinels catch that: a colour that parses
  # displaces at least one of them (it cannot equal both).
  OPACITY_PROBE_JS = <<~JS
    (color) => {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      const ctx = canvas.getContext("2d", { willReadFrequently: true });

      const parses = ["#123456", "#654321"].some((sentinel) => {
        ctx.fillStyle = sentinel;
        ctx.fillStyle = color;
        return ctx.fillStyle !== sentinel;
      });
      if (!parses) return "unparseable";

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

  # Any background utility carrying an alpha suffix, in any variant.
  #
  # MATCHES:   bg-gray-800/50 · dark:group-hover:bg-blue-900/10 · bg-white/80
  #            bg-black/5 · bg-primary/20 · bg-[#fafcff]/50 · bg-gray-800/[0.5]
  # IGNORES:   bg-white · bg-[#fafcff] · dark:bg-gray-900 · bg-gradient-to-r
  #            text-gray-500/50 (not a background) · decoration-current/60
  #
  # The shade-number form (`bg-[a-z]+-\d+/\d+`) was too narrow: it saw none of
  # `bg-white/NN`, `bg-black/NN`, `bg-primary/NN` (~30 call sites in this repo)
  # or arbitrary alphas. The cases above are asserted against this literal in
  # "the translucency pattern recognises every alpha form" below.
  TRANSLUCENT_BG_PATTERN = %q{/(^|:)bg-\S+\/(\d+(\.\d+)?|\[[^\]]+\])$/}

  # Only the MASKING elements. Descendants of a sticky cell composite over its
  # opaque background, so translucency there is harmless and correct — the
  # "Pending archive" badge, search `<mark>`s and hover affordances all use it.
  # Sweeping `.sticky *` made this scan false-fail, with fix guidance pointing
  # at the wrong thing, the moment the fixture grew any of them.
  STICKY_CELL_SELECTOR = "table td.sticky, table th.sticky"

  context "with the matrix scrolled horizontally" do
    setup { visit framework_path(@framework_id) }

    should "paint every sticky cell fully opaque so nothing bleeds through" do
      expand_matrix_row("tr[data-matrix-target='row']")

      result = page.evaluate_script(<<~JS)
        (() => {
          const isOpaque = #{OPACITY_PROBE_JS};
          const isTransparent = (bg) => bg === "transparent" || bg === "rgba(0, 0, 0, 0)";

          const scroller = document.querySelector("[data-matrix-target='scrollContainer']");
          scroller.scrollLeft = scroller.scrollWidth;

          // `fallback` covers a cell whose stickiness lives on an ancestor: the
          // category header's <tr> is the sticky box, the <td> merely carries
          // the background that masks it.
          const cells = [
            { name: "expanded row gutter", selector: "tr[data-matrix-target='expandedRow'] td.sticky" },
            { name: "compact row capability cell", selector: "tr[data-matrix-target='row'] td.sticky" },
            { name: "header corner", selector: "thead th.sticky.left-0" },
            {
              name: "category header band",
              selector: "tr[data-matrix-target='categoryHeader'] td",
              fallback: "tr[data-matrix-target='categoryHeader']"
            }
          ];

          const probed = cells.map(({ name, selector, fallback }) => {
            const el = document.querySelector(selector);
            if (!el) return { name, state: "missing", selector };

            let bg = getComputedStyle(el).backgroundColor;
            let source = selector;
            if (isTransparent(bg) && fallback) {
              const ancestor = document.querySelector(fallback);
              if (ancestor) {
                bg = getComputedStyle(ancestor).backgroundColor;
                source = fallback;
              }
            }
            return { name, state: "probed", bg, source, opaque: isOpaque(bg) };
          });

          return { scrollLeft: scroller.scrollLeft, probed };
        })()
      JS

      # Without real horizontal overflow there is nothing to bleed through and
      # the assertions below would pass vacuously.
      assert_operator result["scrollLeft"], :>, 0,
                      "matrix did not scroll horizontally — fixture is no longer wide enough"

      result["probed"].each do |cell|
        refute_equal "missing", cell["state"],
                     "no element matched #{cell["selector"].inspect} — the sticky cell this " \
                     "test guards has moved or stopped rendering"

        refute_equal "unparseable", cell["opaque"],
                     "probe could not parse the computed colour #{cell["bg"].inspect} for the " \
                     "#{cell["name"]} — the canvas probe needs teaching, the app may be fine"

        assert_equal true, cell["opaque"],
                     "the #{cell["name"]} (#{cell["source"]}) is not opaque (#{cell["bg"]}) — " \
                     "content scrolling beneath it will show through"
      end
    end

    should "declare no translucent background on any sticky cell, hover included" do
      # No row expansion here: the scan reads class lists, which querySelectorAll
      # returns whether or not the expanded row is hidden.
      #
      # The computed check above only sees the resting state. A `/NN` alpha
      # hiding in a hover or dark variant bleeds only while hovering, or only
      # in dark mode — which is exactly how `dark:group-hover:bg-gray-800/50`
      # survived on the compact row. Read the class lists so every variant is
      # covered.
      result = page.evaluate_script(<<~JS)
        (() => {
          const cells = document.querySelectorAll("#{STICKY_CELL_SELECTOR}");
          const offenders = [];
          for (const el of cells) {
            for (const token of el.classList) {
              if (#{TRANSLUCENT_BG_PATTERN}.test(token)) offenders.push(token);
            }
          }
          return { scanned: cells.length, offenders: [ ...new Set(offenders) ] };
        })()
      JS

      # A scan that reaches nothing reports "clean" — assert it actually looked.
      assert_operator result["scanned"], :>=, MIN_STICKY_CELLS,
                      "only #{result["scanned"]} sticky cell(s) matched " \
                      "#{STICKY_CELL_SELECTOR.inspect} — the scan is no longer reaching the " \
                      "matrix, so its clean result means nothing"

      assert_empty result["offenders"],
                   "translucent background(s) on a sticky matrix cell: " \
                   "#{result["offenders"].inspect} — use the opaque composite instead " \
                   "(framework-explorer.md, Hard-Won Lesson 24)"
    end

    should "recognise every alpha form the translucency pattern must catch" do
      # The pattern is the whole guard: a form it misses is a bleed it never
      # reports. Exercised in the browser so this asserts the exact literal the
      # scan above runs, not a Ruby transliteration of it.
      verdicts = page.evaluate_script(<<~JS)
        (() => {
          const pattern = #{TRANSLUCENT_BG_PATTERN};
          const check = (tokens) => tokens.map((t) => [ t, pattern.test(t) ]);
          return {
            translucent: check([
              "bg-gray-800/50", "dark:group-hover:bg-blue-900/10", "bg-white/80",
              "bg-black/5", "bg-primary/20", "bg-[#fafcff]/50", "bg-gray-800/[0.5]"
            ]),
            opaque: check([
              "bg-white", "bg-[#fafcff]", "dark:bg-gray-900", "bg-gradient-to-r",
              "text-gray-500/50", "decoration-current/60"
            ])
          };
        })()
      JS

      verdicts["translucent"].each do |token, matched|
        assert_equal true, matched, "#{token} is translucent but the pattern does not catch it"
      end

      verdicts["opaque"].each do |token, matched|
        assert_equal false, matched, "#{token} is not a translucent background but the pattern flags it"
      end
    end
  end
end
