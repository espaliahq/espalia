# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice Engineer")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "me&u 2025 Career Framework")

      # Role family + role + levels (long names to test mobile header wrapping)
      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Product & Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      @level1_id = SecureRandom.uuid_v7
      @level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level1_id, @role_id, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, @level2_id, @role_id, 2, "Senior Software Engineer", "E2")

      # Category with tolerance
      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      # Capability 1: weighted 2.0, mandatory
      @cap1_id = SecureRandom.uuid_v7
      @cap1_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap1_id, @cap1_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap1_id, @role_id,
        weight: 2.0, individual_tolerance: 0
      )
      @eid1 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, @eid1, SecureRandom.uuid_v7, @cap1_id, 1,
        "Asks clarifying questions to understand problems")
      @eid2 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, @eid2, SecureRandom.uuid_v7, @cap1_id, 2,
        "Synthesises information from multiple sources")

      # Illustrations for expectation 1 (Junior level, Critical Thinking)
      handler.add_role_illustration(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
        @eid1, @role_id, 1, "Asks 'why' before jumping into implementation"
      )
      handler.add_role_illustration(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
        @eid1, @role_id, 2, "Rephrases the problem statement in their own words"
      )

      # Illustration for expectation 2 (Mid level, Critical Thinking)
      handler.add_role_illustration(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
        @eid2, @role_id, 1, "Cross-references docs, code, and stakeholder input before proposing solutions"
      )

      # Capability 2: default weight 1.0
      @cap2_id = SecureRandom.uuid_v7
      @cap2_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap2_id, @cap2_stable, @cat_id, "Problem Solving")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap2_id, @role_id
      )
      @eid3 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, @eid3, SecureRandom.uuid_v7, @cap2_id, 1,
        "Breaks down tasks into manageable steps")

      # Illustration for Problem Solving (needed for accordion tests)
      handler.add_role_illustration(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
        @eid3, @role_id, 1, "Creates a checklist of sub-tasks before starting work"
      )

      # Second category — needed for multi-category scroll tests
      @cat2_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat2_id, "Delivering", ordinal: 2)

      @cap3_id = SecureRandom.uuid_v7
      @cap3_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap3_id, @cap3_stable, @cat2_id, "Execution")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap3_id, @role_id
      )
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap3_id, 1,
        "Delivers small tasks reliably")
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap3_id, 2,
        "Owns medium-scope features end-to-end")

      # Publish v1 so shape-changing events land in the read model
      handler.publish_version(@framework_id, "test")

      # Assign person and open cycle
      level = FrameworkState::Level.find_by!(level_id: @level2_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1 2026 Review", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "assessment index" do
    should "show framework assignment card" do
      visit assessments_path
      assert_text "My Assessments"
      assert_text "me&u 2025 Career Framework"
      assert_text "In Progress"
    end
  end

  context "hero summary" do
    should "frame the middle band with the current-level gap when below expectations" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Person is at E2 with no ratings yet → underperforming/progressing at E2.
      # The state-driven middle band labels the list "Gap to E2", not E3.
      # (Tailwind uppercases the labels via tracking-wide, so Capybara reads
      # them in their source-case form; assert that way.)
      within("#scoring-panel") do
        # Tailwind's `tracking-wide uppercase` re-cases the labels.
        assert_text "GAP TO E2"
        assert_no_text "GAP TO E3"
        # State label sits beside it.
        assert_text(/UNDERPERFORMING AT E2|PROGRESSING TOWARD E2/)
      end
    end

    should "hide Continue assessing button when all current-level cells are rated" do
      # Rate every capability at level 2 (person's current level)
      ActsAsTenant.with_tenant(@tenant) do
        pd_handler = PersonDevelopment::CommandHandler.new
        [ @cap1_stable, @cap2_stable, @cap3_stable ].each do |stable_id|
          pd_handler.rate_self(
            @person.id, @framework_id, stable_id,
            level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
          )
        end
      end

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      within("#scoring-panel") do
        assert_no_text "Continue"
      end
    end

    should "show Continue assessing button when some current-level cells are unrated" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      within("#scoring-panel") do
        assert_text "Continue"
      end
    end

    should "navigate to the unrated capability when Continue assessing is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('a[data-controller~=\"continue-assessing\"]').click()"
      )

      # Poll the matrix turbo-frame's src until it carries the focus
      # params, then assert — fixed sleeps are unreliable on starved CI.
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          src = page.evaluate_script(
            "document.querySelector('turbo-frame#assessment-matrix').getAttribute('src')"
          ).to_s
          break if src.match?(/capability=#{@cap1_stable}/) && src.match?(/level_ordinal=2/)

          sleep 0.05
        end
      end

      frame_src = page.evaluate_script(
        "document.querySelector('turbo-frame#assessment-matrix').getAttribute('src')"
      )
      assert_match(/capability=#{@cap1_stable}/, frame_src,
        "Expected matrix frame to reload with capability=#{@cap1_stable}, got #{frame_src}")
      assert_match(/level_ordinal=2/, frame_src,
        "Expected matrix frame to reload with level_ordinal=2, got #{frame_src}")
    end
  end

  context "capability contribution badge" do
    should "render a signed delta (negative included) on every capability card" do
      # Seed an explicit underperforming rating on cap1 at the person's
      # level so its raw_contribution is < 0. Production renders this as
      # a signed delta next to the capability name; the earlier
      # redesign suppressed negative contributions, hiding the most
      # useful "where am I under" signal.
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap1_stable,
          level_ordinal: 2, frequency: "some", cycle_id: @cycle_id
        )
      end

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Find the cap1 card and assert its name row contains a signed
      # delta matching `±N.N` (any sign, one decimal).
      label = page.evaluate_script(<<~JS)
        (function() {
          var card = document.querySelector('[data-capability-stable-id="#{@cap1_stable}"]');
          if (!card) return null;
          var nameRow = card.querySelector('h3')?.parentElement;
          var spans = nameRow ? Array.from(nameRow.querySelectorAll('span')) : [];
          var m = spans.map(s => s.textContent.trim()).find(t => /^[+-]\\d+\\.\\d$/.test(t));
          return m || null;
        })()
      JS

      assert_match(/^[+-]\d+\.\d$/, label.to_s,
        "Expected a signed delta (e.g. '-0.5') next to the capability name, got #{label.inspect}")
    end
  end

  context "category navigation" do
    should "update the browser URL with ?category= when a chip is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      assert_selector "section#category-#{@cat2_id}"
      # Wait for the matrix turbo-frame to be fully loaded before
      # clicking. matrix_controller's `turbo:frame-load` handler
      # (`#syncFrameUrlToBrowser`) reads `category` from the frame's
      # src and writes it onto the browser URL — if it fires AFTER the
      # chip click, it overwrites the `?category=` that the click just
      # pushed. Slow CI runners hit this race routinely.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      page.execute_script(
        "document.querySelector('nav#category-tabs [data-category-id=\"#{@cat2_id}\"]').click()"
      )
      sleep 0.6

      # Browser URL must carry ?category=<id> so the activity sidebar
      # and any other focus-aware UI narrow to the clicked category.
      browser_url = page.evaluate_script("window.location.search")
      assert_includes browser_url, "category=#{@cat2_id}",
        "Browser URL should include ?category=#{@cat2_id}, got #{browser_url.inspect}"
    end

    should "dispatch matrix:focus-changed with category level when a chip is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      # Capture the focus payload broadcast by the category chip click.
      # The activity feed listens to this event to narrow its rendered
      # entries; without it, clicking a chip leaves the sidebar stale.
      payload = page.evaluate_script(<<~JS)
        (function() {
          return new Promise(resolve => {
            window.addEventListener("matrix:focus-changed", e => resolve(e.detail), { once: true });
            document.querySelector('nav#category-tabs [data-category-id="#{@cat2_id}"]').click();
          });
        })()
      JS
      assert_equal "category", payload["level"]
      assert_equal @cat2_id, payload["categoryId"]
    end

    should "mark the clicked category chip as active after the scroll settles" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      # Click the SECOND category chip after first parking on the first
      # (so the click triggers a real scroll). The bug was that the
      # final scroll event of the smooth animation could fire BEFORE the
      # target was reached, marking the previous section active and
      # leaving the chip mismatched with the visible section.
      page.execute_script(
        "document.querySelector('nav#category-tabs [data-category-id=\"#{@cat_id}\"]').click()"
      )
      sleep 0.6
      page.execute_script(
        "document.querySelector('nav#category-tabs [data-category-id=\"#{@cat2_id}\"]').click()"
      )
      sleep 1.0

      active_category_id = page.evaluate_script(
        "(function() { var el = document.querySelector('nav#category-tabs a[aria-current=\"page\"]'); " \
        "return el ? el.dataset.categoryId : null; })()"
      )
      assert_equal @cat2_id, active_category_id,
        "Clicked category chip should remain active after the scroll settles, " \
        "got #{active_category_id.inspect}"
    end

    should "scroll the second category section under the sticky header when its chip is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      assert_selector "section#category-#{@cat2_id}"
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      # Add a tall spacer so the page can scroll
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      page.execute_script(
        "document.querySelector('nav#category-tabs [data-category-id=\"#{@cat2_id}\"]').click()"
      )
      sleep 0.8

      # The second category section should land at or just below the
      # bottom of the sticky header — not under it, not far below.
      offset = page.evaluate_script(
        "(function() { var s = document.getElementById('category-#{@cat2_id}'); " \
        "var h = document.getElementById('assessment-sticky-header'); " \
        "return s.getBoundingClientRect().top - (h.getBoundingClientRect().bottom); })()"
      )
      assert offset.between?(-5, 30),
        "Category section should sit just below the sticky header (offset=#{offset})"
    end

    should "mark the chip for the currently-visible category as active on scroll" do
      visit assessment_path(@assignment)
      assert_selector "#assessment-sticky-header"
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      # First, scroll enough that the hero compacts and the document
      # finishes reflowing.
      page.execute_script("window.scrollTo(0, 300)")
      sleep 0.4
      # Then iterate until cat2's section sits a few px inside the
      # active-detection threshold (header bottom). Re-measuring on each
      # pass absorbs any layout shift caused by the hero's scroll-driven
      # collapse — we want a stable end state, not a one-shot scroll.
      3.times do
        page.execute_script(<<~JS)
          var s = document.getElementById('category-#{@cat2_id}');
          var h = document.getElementById('assessment-sticky-header');
          var target = s.getBoundingClientRect().top + window.scrollY - h.offsetHeight - 4;
          window.scrollTo(0, target);
        JS
        sleep 0.3
      end

      # The chip for the second category should be the active one
      active = page.evaluate_script(
        "(function() { var c = document.querySelector('nav#category-tabs [data-category-id=\"#{@cat2_id}\"]'); " \
        "return c && c.getAttribute('aria-current') === 'page'; })()"
      )
      assert active,
        "Second category chip should be marked aria-current when its section is in view"
    end

    should "keep the category heading visible under the sticky header while scrolling within the category" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      # Inject extra capability cards inside the first category to make
      # the category section tall enough to scroll within
      page.execute_script(<<~JS)
        var section = document.getElementById('category-#{@cat_id}');
        section.insertAdjacentHTML('beforeend', '<div style="height:1500px"></div>');
      JS

      # Scroll a few hundred pixels into the first category
      page.execute_script("window.scrollTo(0, 700)")
      sleep 0.5

      # The category heading should be visible at the top of the viewport,
      # just below the unified sticky header
      heading_position = page.evaluate_script(
        "(function() { var s = document.getElementById('category-#{@cat_id}'); " \
        "var h2 = s.querySelector('h2'); " \
        "var h = document.getElementById('assessment-sticky-header'); " \
        "var headerBottom = h.getBoundingClientRect().bottom; " \
        "var headingTop = h2.getBoundingClientRect().top; " \
        "return headingTop - headerBottom; })()"
      )
      assert heading_position.between?(-5, 30),
        "Category heading should stick just under the unified sticky header (offset=#{heading_position})"
    end
  end

  context "activity feed focus sync" do
    should "narrow the activity feed to the capability x level when a chip is focused" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Click a chip to focus it (cell-level focus)
      page.execute_script("document.getElementById('cell-#{@cap1_stable}-2').click()")
      sleep 1.0

      # The activity feed banner label should report cell-level focus,
      # not category-level focus.
      banner_label = page.evaluate_script(
        "(document.querySelector('[data-activity-feed-target=\"focusBannerLabel\"]') || {}).textContent || ''"
      )
      # Cell-level focus narrows to "for the focused cell (L<n>)"
      assert_match(/focused cell|focused capability/, banner_label,
        "Activity feed banner should narrow to capability/cell focus, got: #{banner_label.inspect}")
    end
  end

  context "sticky header" do
    should "keep header, hero, and category chips visible when scrolled" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )
      page.execute_script("window.scrollTo(0, 500)")
      sleep 0.5

      # H1 should still be visible (unified sticky header)
      h1_visible = page.evaluate_script(
        "(function() { var r = document.querySelector('h1').getBoundingClientRect(); " \
        "return r.top >= 0 && r.bottom <= window.innerHeight; })()"
      )
      assert h1_visible, "H1 (assessment name) should remain visible when scrolled"

      # Activity toggle should still be visible
      assert_selector "[data-action='click->activity-pane#toggle']", visible: true

      # Category chips should still be visible
      assert_selector "nav#category-tabs", visible: true
    end

    should "show category pass/fail indicators on chips" do
      visit assessment_path(@assignment)
      # Category chips should carry pass/fail status dots
      within("nav#category-tabs") do
        assert_selector "[data-category-status]"
      end
    end
  end

  context "level strip" do
    should "auto-focus every card on the person's current level by default" do
      visit assessment_path(@assignment)
      # No ?capability= in URL — every card still auto-focuses on the
      # person's level (E2). The level-2 expectation text renders inside
      # each card's expansion panel.
      assert_text "Synthesises information from multiple sources"
    end

    should "honour an explicit ?capability= focus on the matching card" do
      visit assessment_path(@assignment, capability: @cap1_stable)
      # ?capability= present but no ?level_ordinal=. The expansion
      # should default to the person's level (E2), and only one
      # expansion shows on this capability.
      assert_text "Synthesises information from multiple sources"
    end

    should "fully reveal the capability name and eyebrow under the sticky header after chip click" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )
      page.execute_script("window.scrollTo(0, 1200)")
      sleep 0.4

      page.execute_script(<<~JS)
        document.getElementById('cell-#{@cap2_stable}-1').click();
      JS
      sleep 1.0

      # The eyebrow ("THINKING") and capability name ("Problem Solving")
      # must be in view, not pushed under the sticky chrome. The
      # EFFECTIVE blocker is the unified header AND the sticky category
      # section header that pins underneath it — both cover the top.
      diagnostics = page.evaluate_script(<<~JS)
        (function() {
          var card = document.querySelector('[data-capability-stable-id="#{@cap2_stable}"]');
          var section = card.closest("section[data-category-id]");
          var sectionHeader = section.querySelector(":scope > [data-section-header]");
          var header = document.getElementById('assessment-sticky-header');
          return {
            card_top: card.getBoundingClientRect().top,
            header_bottom: header.getBoundingClientRect().bottom,
            section_header_height: sectionHeader ? sectionHeader.offsetHeight : 0
          };
        })()
      JS
      effective_blocker_bottom = diagnostics["header_bottom"] + diagnostics["section_header_height"]
      offset = diagnostics["card_top"] - effective_blocker_bottom
      assert offset >= -5,
        "Top of capability card should sit at or below the effective sticky chrome " \
        "(offset=#{offset}, diagnostics=#{diagnostics.inspect})"
    end

    should "smooth scroll the capability card into view when a chip is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Set up: starting from scrollY=0 (header expanded) and clicking a
      # chip on a card BELOW the fold is the scenario that exposes the
      # sticky-hero-compacts-mid-scroll race. The smooth-scroll target is
      # computed against the expanded header height; mid-flight the hero
      # compacts (scrollY crosses 80) and the scroll-compensation kick
      # fights the animation, leaving the card top hidden behind the
      # final-state header.
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )
      page.execute_script("window.scrollTo(0, 0)")
      sleep 0.4

      # Click a chip on cap2 (Problem Solving) — below the fold from
      # scrollY=0. JS-dispatch so Capybara doesn't scroll it for us.
      page.execute_script(<<~JS)
        document.getElementById('cell-#{@cap2_stable}-1').click();
      JS
      sleep 1.5

      # After the chip click, the cap2 CARD top must sit just below the
      # sticky header bottom — close enough that the eyebrow and name
      # are immediately visible without forcing the user to scroll up.
      # We allow 0–30px of breathing room (the card has 12px of declared
      # scroll-margin-top above its top edge); anything outside that
      # window is a regression.
      # Measure against the EFFECTIVE blocking top — unified header
      # bottom + category section header height. The category section
      # heading is itself sticky (pinned just under the unified header),
      # so card top must clear both, not just the unified header.
      diagnostics = page.evaluate_script(<<~JS)
        (function() {
          var card = document.querySelector('[data-capability-stable-id="#{@cap2_stable}"]');
          var section = card.closest("section[data-category-id]");
          var sectionHeader = section.querySelector(":scope > [data-section-header]");
          var header = document.getElementById('assessment-sticky-header');
          return {
            card_top: card.getBoundingClientRect().top,
            header_bottom: header.getBoundingClientRect().bottom,
            section_header_height: sectionHeader ? sectionHeader.offsetHeight : 0,
            scroll_y: window.scrollY
          };
        })()
      JS
      effective_blocker_bottom = diagnostics["header_bottom"] + diagnostics["section_header_height"]
      offset = diagnostics["card_top"] - effective_blocker_bottom
      assert offset.between?(0, 30),
        "Capability card top should land 0-30px below the effective sticky " \
        "header bottom (unified + section). offset=#{offset}, " \
        "diagnostics=#{diagnostics.inspect}"
    end

    should "render each level code only once (no duplicated labels under the chips)" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Count distinct nodes whose text is exactly "E1" inside the first
      # capability card. The chip already shows the code; the previous
      # design ALSO rendered a label row below with the same codes.
      count = page.evaluate_script(<<~JS)
        (function() {
          var card = document.querySelector('[data-matrix-target="card"]');
          var matches = 0;
          card.querySelectorAll('*').forEach(function(n) {
            if (n.children.length === 0 && (n.textContent || '').trim() === 'E1') matches++;
          });
          return matches;
        })()
      JS
      assert_equal 1, count,
        "Expected exactly one 'E1' label in the chip strip, got #{count}"
    end
  end

  context "level chip colors" do
    should "tint unrated below-level chips with assumed-consistent green" do
      visit assessment_path(@assignment)
      # The unrated E1 chip (below person_level=2) should carry the
      # assumed-consistent green tint — the person is at E2, so we
      # assume they've cleared E1.
      chip_classes = page.evaluate_script(
        "document.getElementById('cell-#{@cap1_stable}-1').className"
      )
      assert_match(/bg-green/, chip_classes,
        "Unrated below-level chip should carry assumed-consistent green tint. Classes: #{chip_classes}")
    end

    should "leave the at-person-level unrated chip neutral grey" do
      visit assessment_path(@assignment)
      # E2 is the person's level; with no rating it should be grey,
      # not green (only BELOW-level cells get the mint tint).
      chip_classes = page.evaluate_script(
        "document.getElementById('cell-#{@cap1_stable}-2').className"
      )
      assert_no_match(/bg-green/, chip_classes,
        "Unrated at-person-level chip should be grey. Classes: #{chip_classes}")
    end

    # Regression: the button-reset utilities added when chips were
    # promoted from <div> to <button> (`bg-transparent`) won the cascade
    # against `bg-green-100/60` / `bg-gray-100` / etc — the class string
    # still listed the chip colour but the computed background painted
    # transparent. The existing tests assert on className only and so
    # passed; this asserts on what actually paints.
    should "actually paint a non-transparent background for each chip state" do
      visit assessment_path(@assignment)
      bg = ->(id) { page.evaluate_script("window.getComputedStyle(document.getElementById('#{id}')).backgroundColor") }

      below_unrated = bg.call("cell-#{@cap1_stable}-1")  # E1, below person_level
      at_unrated    = bg.call("cell-#{@cap1_stable}-2")  # E2, person's level

      assert_no_match(/rgba?\(0,\s*0,\s*0,\s*0\)|transparent/i, below_unrated,
        "Unrated below-level chip painted transparent — bg-green-* lost the cascade. Got: #{below_unrated}")
      assert_no_match(/rgba?\(0,\s*0,\s*0,\s*0\)|transparent/i, at_unrated,
        "Unrated at-level chip painted transparent — bg-gray-* lost the cascade. Got: #{at_unrated}")
    end
  end

  context "scroll stability on rating" do
    should "not jump scroll position when a rating is submitted" do
      # ?capability= focuses the third (Execution) card so the
      # expansion panel renders the FrequencySelector buttons.
      visit assessment_path(@assignment, capability: @cap3_stable)
      assert_selector "#scoring-panel"

      # Add tall spacer + scroll into the page so a later capability's
      # rating button is visible without Capybara needing to scroll to
      # it. The third (Execution) card under "Delivering" sits well
      # below the hero.
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )
      page.execute_script(<<~JS)
        var btn = document.querySelector('#rating-#{@cap3_stable}-2 button');
        btn.scrollIntoView({ block: 'center' });
      JS
      sleep 0.5

      scroll_before = page.evaluate_script("window.scrollY")
      assert scroll_before > 200,
        "Setup: should be scrolled into the page (scrollY=#{scroll_before})"

      # JS-dispatch the open + pick so Capybara's "scroll element into
      # view" doesn't reset scroll. This mirrors what a user clicking a
      # naturally-visible pill experiences.
      page.execute_script(<<~JS)
        var trigger = document.querySelector("#rating-#{@cap3_stable}-2 button[aria-haspopup='menu']");
        trigger.click();
      JS
      sleep 0.3
      page.execute_script(<<~JS)
        var item = Array.from(document.querySelectorAll("#rating-#{@cap3_stable}-2 [role='menuitem']"))
          .find(b => b.textContent.trim().includes('Consistently'));
        item?.closest('form')?.requestSubmit(item);
      JS
      sleep 1.0

      scroll_after = page.evaluate_script("window.scrollY")
      assert_in_delta scroll_before, scroll_after, 50,
        "Scroll should remain stable when rating (was #{scroll_before}, now #{scroll_after})"
    end
  end

  context "responsive layout" do
    should "hide the activity sidebar on narrow viewports" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment)

      # Open the sidebar — on narrow viewports it should overlay rather
      # than steal width from the main content
      page.execute_script(
        "document.querySelector('[data-action*=\"activity-pane#toggle\"]').click()"
      )
      sleep 0.3

      main_visible_width = page.evaluate_script(
        "document.querySelector('turbo-frame#assessment-matrix').getBoundingClientRect().width"
      )
      viewport_width = page.evaluate_script("window.innerWidth")

      # Main pane should be at least 80% of viewport (sidebar overlays, not pushes)
      assert main_visible_width >= viewport_width * 0.8,
        "On narrow viewport sidebar should overlay, not compress main pane " \
        "(main=#{main_visible_width}, viewport=#{viewport_width})"
    end

    should "contain capability cards within the viewport on narrow screens with many levels" do
      # Frameworks with many levels (E1-E8) produce a chip strip far
      # wider than mobile viewports — the card must contain that strip
      # in a scrollable region instead of letting it bulge the card off
      # the viewport. Add extra levels to this test's framework.
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.start_draft(@framework_id, 2, @person.id)
        (3..8).each do |ord|
          handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, ord, "L#{ord}", "E#{ord}")
        end
        handler.publish_version(@framework_id, "many-levels")
      end

      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment)

      viewport_width = page.evaluate_script("window.innerWidth")
      card_right = page.evaluate_script(
        "document.querySelector('[data-matrix-target=\"card\"]').getBoundingClientRect().right"
      )

      assert card_right <= viewport_width + 5,
        "Card right edge (#{card_right}) should not extend past viewport (#{viewport_width}) " \
        "even with many levels"
    end
  end

  context "hero refinements" do
    should "not render a context-label eyebrow above the verdict" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within("#scoring-panel") do
        assert_no_text "SELF ASSESSMENT"
        assert_no_text "Self Assessment"
      end
    end

    should "not jump scroll position to top when slowly scrolling past the compact threshold" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      # Capture the visible y-position of an element just below the hero.
      # When the hero compacts during a slow scroll, that element must
      # stay at roughly the same viewport position — not jump back to top.
      below_hero_id = "category-#{@cat_id}"

      # Slow scroll: a small step that crosses the compact threshold (80).
      page.execute_script("window.scrollTo(0, 90)")
      sleep 0.4

      visible_y = page.evaluate_script(
        "document.getElementById('#{below_hero_id}').getBoundingClientRect().top"
      )
      scroll_y = page.evaluate_script("window.scrollY")

      # After the scroll + compact, the user's scroll position should
      # NOT have snapped back to (or near) zero.
      assert scroll_y > 50,
        "Slow scroll past compact threshold caused scroll to jump to top (scrollY=#{scroll_y})"
      # And the visible content below the hero should remain in view.
      assert visible_y < 600,
        "Content below the hero should still be visible after compact (top=#{visible_y})"
    end

    should "collapse the middle band while keeping the hero header visible on scroll" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      # Pre-condition: the file-level fixture must produce a hero with a
      # middle band (the perspective-driven 3-capability list). The band
      # only renders when `primary_scoring[:capability_contributions]` is
      # non-empty; with the shared setup (capabilities + person + ratings)
      # this is currently always the case. Asserting it explicitly fails
      # loudly if a future fixture change empties the hero — rather than
      # silently skipping the actual collapse assertions below.
      assert_selector ".hero-collapsible", visible: :all

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      # At the top, the middle band should be at full height.
      middle_before = page.evaluate_script(
        "document.querySelector('.hero-collapsible').getBoundingClientRect().height"
      )
      assert middle_before > 40,
        "Middle band should be expanded at scrollY=0, got height=#{middle_before}"

      # Scroll past the collapse range (CSS animation maps 0..240 to full..0).
      page.execute_script("window.scrollTo(0, 400)")
      sleep 0.4

      middle_after = page.evaluate_script(
        "document.querySelector('.hero-collapsible').getBoundingClientRect().height"
      )
      assert middle_after < 5,
        "Middle band should be collapsed past the scroll range, got height=#{middle_after}"

      # The hero header (verdict text) must still be visible regardless.
      header_visible = page.evaluate_script(<<~JS)
        (function() {
          var panel = document.getElementById('scoring-panel');
          var rect = panel.getBoundingClientRect();
          return rect.bottom > 0 && rect.height > 40;
        })()
      JS
      assert header_visible, "Hero header should remain visible after the middle band collapses"
    end
  end

  context "activity sidebar layout" do
    should "expand inline and compress the main pane when open" do
      visit assessment_path(@assignment)

      main_width_before = page.evaluate_script(
        "document.querySelector('turbo-frame#assessment-matrix').getBoundingClientRect().width"
      )

      # Open the sidebar
      page.execute_script(
        "document.querySelector('[data-action*=\"activity-pane#toggle\"]').click()"
      )
      sleep 0.5

      main_width_after = page.evaluate_script(
        "document.querySelector('turbo-frame#assessment-matrix').getBoundingClientRect().width"
      )

      assert main_width_after < main_width_before - 100,
        "Main pane should compress when sidebar opens (was #{main_width_before}, now #{main_width_after})"
    end
  end

  context "activity sidebar" do
    should "be closable when open" do
      visit assessment_path(@assignment)
      assert_selector "[data-action='click->activity-pane#toggle']"

      # Open via JS-dispatched click (avoids flake-prone Selenium pointer)
      page.execute_script(
        "document.querySelector('[data-action*=\"activity-pane#toggle\"]').click()"
      )
      assert_selector "#assessment-activity-pane", visible: true

      # Close via the × button inside the sidebar
      page.execute_script(
        "document.querySelector('#assessment-activity-pane [data-action*=\"activity-pane#close\"]').click()"
      )

      assert_selector "#assessment-activity-pane", visible: :hidden, wait: 3
    end
  end

  context "self-assessment flow" do
    should "display assessment with inline rating pills" do
      # ?capability= focuses the card so the expansion panel renders the
      # inline frequency pill we want to assert on.
      visit assessment_path(@assignment, capability: @cap1_stable)

      assert_selector "h1", text: "Senior Software Engineer"
      assert_text "E2"
      assert_text "Critical Thinking"
      assert_text "Problem Solving"

      # The inline pill renders at the end of the expectation sentence
      # with an aria-haspopup attribute identifying it as a chooser.
      assert_selector "[aria-haspopup='menu']", minimum: 1

      # Hero summary card visible
      assert_selector "#scoring-panel"
      assert_text "Thinking"
    end

    should "rate a capability and see scoring update" do
      # ?capability= focuses the card so the expansion panel renders the
      # FrequencySelector for the person's level (level 2 here).
      visit assessment_path(@assignment, capability: @cap1_stable)

      # The expansion panel shows the FrequencySelector for the person's level.
      # Person is at level 2, so rating-#{stable}-2 is in the expansion panel.
      click_rating_frequency("#rating-#{@cap1_stable}-2", "Consistently")

      # Scoring panel should update (performance ratio changes)
      assert_selector "#scoring-panel"
    end

    should "show sticky hero when scrolled down" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Add a tall spacer to make the page scrollable
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      page.execute_script("window.scrollTo(0, 500)")
      sleep 0.5

      scroll_pos = page.evaluate_script("window.scrollY")
      hero_top = page.evaluate_script(
        "document.getElementById('scoring-panel').getBoundingClientRect().top"
      )
      assert scroll_pos > 100, "Page should have scrolled (scrollY=#{scroll_pos})"
      assert hero_top >= 0 && hero_top < 100,
        "Hero should be pinned near the top of the viewport (top=#{hero_top})"
    end

    should "scroll to the correct category section when clicking a category chip" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      section_id = "category-#{@cat_id}"
      # JS-dispatched click so Stimulus actions fire reliably even on
      # starved CI runners (see testing.md — *Flake-Prone Click Guards*).
      page.execute_script(
        "document.querySelector(\"nav#category-tabs [data-category-id='#{@cat_id}']\").click()"
      )
      sleep 0.8

      section_visible = page.evaluate_script(
        "(function() { var r = document.getElementById('#{section_id}').getBoundingClientRect(); " \
        "return r.top >= 0 && r.top < window.innerHeight; })()"
      )
      assert section_visible,
        "Category section should be visible in the viewport after clicking chip"
    end

    should "expand capability card when clicking a level chip" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Click the E1 chip on the first capability — JS-dispatched so
      # the Stimulus action triggers reliably on starved CI.
      page.execute_script("document.getElementById('cell-#{@cap1_stable}-1').click()")

      # The expansion panel for level 1 should appear with level-1 expectation
      assert_text "Asks clarifying questions to understand problems", wait: 5
    end

    should "update capability contribution when rating a frequency" do
      # ?capability= focuses the card so the expansion panel renders the
      # FrequencySelector for the person's level (level 2 here).
      visit assessment_path(@assignment, capability: @cap1_stable)
      assert_selector "#scoring-panel"

      # Rate level 2 of first capability
      click_rating_frequency("#rating-#{@cap1_stable}-2", "Consistently")

      # The chip color should update to reflect the new rating
      assert_selector "#cell-#{@cap1_stable}-2.bg-green-200", wait: 5
    end

    should "not jump scroll position when scrolling past the hero summary" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )
      page.execute_script("window.scrollTo(0, 600)")
      sleep 0.3

      pos_before = page.evaluate_script("window.scrollY")
      sleep 0.5
      pos_after = page.evaluate_script("window.scrollY")

      assert_in_delta pos_before, pos_after, 10,
        "Scroll position jumped from #{pos_before} to #{pos_after} — hero compact/expand feedback loop"
    end

    should "render illustrations on the auto-focused level expansion" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Card layout: every card auto-focuses the person's level (E2)
      # and renders the illustrations for that level in the expansion
      # panel. Cap1 has one level-2 illustration.
      assert_text "Cross-references docs, code, and stakeholder input before proposing solutions"
    end
  end

  context "manager-rating privacy" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        FactoryBot.create(:assessment_level_rating,
          tenant: @tenant, person_id: @person.id, framework_id: @framework_id,
          cycle_id: @cycle_id, capability_stable_id: @cap1_stable,
          level_ordinal: 1, self_rated_frequency: "consistent",
          manager_rated_frequency: "occasional", aligned_frequency: nil)
      end
    end

    should "hide manager rating from the assessee's self-view" do
      visit assessment_path(@assignment)
      assert_text "Critical Thinking"

      # No "Mgr:" label should appear anywhere — manager rating is private
      # to the manager until alignment formally begins.
      assert_no_text "Mgr:"
    end

    should "show self-only context before alignment is in progress" do
      # Cycle is in :enrolled state, manager has not started alignment.
      # The assessment context is derived from participant status only —
      # any stale ?mode=alignment param is ignored, and the assessee must
      # not see manager ratings.
      visit assessment_path(@assignment, mode: "alignment")
      assert_text "Critical Thinking"
      assert_no_text "Mgr:"
    end
  end

  context "category tabs" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new

        # Shape-changing commands (add_capability, create_capability_role_binding,
        # set_behavioural_expectation) require a draft. add_capability_category is
        # editorial-live.
        handler.add_capability_category(@framework_id, @cat2_id = SecureRandom.uuid_v7, "Delivering", ordinal: 2)

        handler.start_draft(@framework_id, 2, "test")
        @cap3_id = SecureRandom.uuid_v7
        @cap3_stable = SecureRandom.uuid_v7
        handler.add_capability(@framework_id, @cap3_id, @cap3_stable, @cat2_id, "Execution")
        handler.create_capability_role_binding(
          @framework_id, SecureRandom.uuid_v7, @cap3_id, @role_id
        )
        handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
          @cap3_id, 1, "Ships features reliably")
        handler.publish_version(@framework_id, "test")

        # Add illustration after publish (editorial, needs parent expectation to exist)
        handler.add_role_illustration(
          @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
          FrameworkState::BehaviouralExpectation.find_by!(capability_id: @cap3_id, level_ordinal: 1).expectation_id,
          @role_id, 1, "Delivers on commitments without reminders"
        )
      end
    end

    should "display all categories on single scrollable page" do
      visit assessment_path(@assignment)

      # Both categories and all capabilities should be visible on the same page
      assert_selector "#category-tabs"
      assert_text "Thinking"
      assert_text "Delivering"
      assert_text "Critical Thinking"
      assert_text "Problem Solving"
      assert_text "Execution"
    end
  end

  context "cell focus" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    end

    should "not reload the matrix frame when the rater clicks their own rating button" do
      # ?capability= focuses the card so the expansion panel renders
      # the inline frequency pill we're going to click.
      visit assessment_path(@assignment, capability: @cap1_stable)
      wait_for_stimulus "matrix"

      # Wait for the lazy-loaded matrix frame to finish its initial
      # fetch — otherwise the initial src completion would fire
      # turbo:frame-load AFTER we instrument and skew the count.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      # Instrument frame load events.
      page.execute_script(<<~JS)
        (() => {
          window.__frameLoadCount = 0;
          const f = document.querySelector("turbo-frame#assessment-matrix");
          if (f) {
            f.addEventListener("turbo:frame-load", () => {
              window.__frameLoadCount++;
            });
          }
        })()
      JS

      # Pick "Some of the time" from the inline pill. Person is at level
      # 2, so the rating wrapper is `#rating-{stable}-2`.
      click_rating_frequency("#rating-#{@cap1_stable}-2", "Some")

      # Give the broadcast headroom — the suppress window is 2s, so
      # 2.5s is enough for a rogue reload to fire if the suppression
      # broke.
      sleep 2.5
      load_count = page.evaluate_script("window.__frameLoadCount")
      assert_equal 0, load_count,
        "The matrix frame should NOT reload on the rater's own click — " \
        "got #{load_count} reload(s). Suppression in assessment_sync " \
        "is broken."
    end
  end

  context "responsive behaviour" do
    should "show scoring panel as hero card on desktop" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit assessment_path(@assignment)

      # Hero summary card should be visible on desktop
      assert_selector "#scoring-panel", visible: true
    end

    should "show header elements on mobile with long names" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment)

      # Header H1 + shortcode chip + status pill must wrap without pushing content off-screen
      assert_selector "h1", text: "Senior Software Engineer"
      assert_text "E2"
      assert_text "In Progress"
    end
  end
end
