# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsSystemTest < ApplicationSystemTestCase
  include ContrastHelpers

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
    should "show framework assignment card with self status (own card hides manager)" do
      visit assessments_path
      assert_text "My Assessments"
      assert_text "me&u 2025 Career Framework"
      # Own card shows the Self chip only — no manager progress pre-alignment.
      assert_text "Self"
      assert_text "Not started"
      assert_no_text "Manager"
    end

    should "keep a long level title inside its card on a phone" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.update_level_details(
          @framework_id, @level2_id, title: "Distinguished Fellow of the Extraordinarily Long Level Title"
        )
      end
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessments_path
      assert_text "Distinguished Fellow"

      assert_no_sideways_overflow("a long level title pushes My Assessments sideways")
    end
  end

  context "hero summary" do
    should "show the priming coverage prompt instead of a score before enough is rated" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within("#scoring-panel") do
        # Neutral coverage prompt — no alarming verdict/score yet.
        assert_text "Rate yourself to see your score"
        assert_text "Score unlocks at 1"
        assert_no_text "Below expectations"
        assert_no_text "demonstrated"
      end
    end

    should "frame the middle band with the current-level gap when below expectations" do
      # Rate one current-level cap "none" so coverage clears the 50% unlock
      # threshold (1 of 2 current-level caps) — surfacing the scoring hero —
      # while staying clearly below expectations at E2.
      rate_to_unlock_hero(frequency: "none")

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Person is at E2, below expectations → underperforming/progressing at E2.
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

    should "read the gap list as percentages, not weight-unit deltas" do
      # #418: every row used to print a signed delta in the engine's own
      # units ("-1.0"), which could only be compared against other rows.
      rate_to_unlock_hero(frequency: "none")

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within("#scoring-panel") do
        assert_text "GAP TO E2"
        # Each row names a capability and its share of that level.
        assert_text(/\d+%/)
        assert_no_text(/[+\u2212-]\d\.\d/)
      end
    end

    should "show the score bar pinned at the top of the ladder at both viewports" do
      # This role's ladder ends at E2, so a fully consistent E2 is the top of
      # the ladder: the bar is a single 0–100 segment and the copy says so.
      ActsAsTenant.with_tenant(@tenant) do
        pd_handler = PersonDevelopment::CommandHandler.new
        [ @cap1_stable, @cap2_stable, @cap3_stable ].each do |stable_id|
          pd_handler.rate_self(@person.id, @framework_id, stable_id,
                               level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
        end
      end

      [ DESKTOP_SIZE, MOBILE_SIZE ].each do |size|
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_selector "#scoring-panel"

        within("#scoring-panel") do
          assert_selector "#hero-score-bar [role='progressbar'][aria-valuemax='100'][aria-valuenow='100']"
          assert_text "100% · E2"
          assert_no_text "200%"
          assert_text "100% of E2 demonstrated · no level above E2."
          assert_text "You're meeting E2 expectations — the top of the ladder."
          # Tailwind's `tracking-wide uppercase` re-cases the panel labels.
          assert_text "MEETING E2 · TOP OF THE LADDER"
        end

        # The bar must never push the document sideways or sit over the
        # headline — below `sm` the header stacks (found by the visual pass).
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
               "the hero must not make the page scroll sideways at #{size.join('x')}"
        overlap = page.evaluate_script(<<~JS)
          (() => {
            const h = document.querySelector("#scoring-panel h2").getBoundingClientRect();
            const b = document.querySelector("#hero-score-bar").getBoundingClientRect();
            return h.right > b.left && b.right > h.left && h.bottom > b.top && b.bottom > h.top;
          })()
        JS
        assert_not overlap, "the score bar must not overlap the headline at #{size.join('x')}"
        clipped = page.evaluate_script(<<~JS)
          (() => {
            const card = document.querySelector("#scoring-panel").getBoundingClientRect();
            const bar = document.querySelector("#hero-score-bar").getBoundingClientRect();
            return bar.right > card.right - 8;
          })()
        JS
        assert_not clipped, "the score bar's last tick must stay inside the card at #{size.join('x')}"
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
      # Unlock the scoring hero (rates cap1); cap3 stays unrated so the
      # "Continue" nudge still has a target in the unlocked header.
      rate_to_unlock_hero

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

  context "capability score row" do
    should "read each capability on the assessment's own scale" do
      # Three shapes on one page, all from the same components: a rated
      # capability shows its percent plus the bar, an unrated one says so
      # rather than reading 0%, and one with no expectation at the
      # assessed level says that instead of a number.
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap1_stable,
          level_ordinal: 2, frequency: "some", cycle_id: @cycle_id
        )
      end

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      rated = find("#capability-name-#{@cap1_stable} [data-capability-score]")
      assert_match(/\d+%/, rated.text,
        "Expected the rated capability's score as a percent, got #{rated.text.inspect}")
      assert_selector "#capability-name-#{@cap1_stable} [data-score-bar] [role='progressbar']"

      # Problem Solving has an expectation at E1 only.
      assert_selector "#capability-name-#{@cap2_stable} [data-capability-score]", text: "No expectation at E2"

      # Execution has an E2 cell but no rating yet.
      assert_selector "#capability-name-#{@cap3_stable} [data-capability-score]", text: "Not rated"
    end

    # #431: the binding facts that change how a rating lands — counts ×2,
    # cannot be short — showed nowhere on the card before it was rated.
    should "flag a capability that counts double or is Required, and only that one" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within "#capability-name-#{@cap1_stable}" do
        assert_selector "button[aria-describedby='assessment-term-weight-#{@cap1_stable}']", text: "×2"
        assert_selector "button[aria-describedby='assessment-term-required-#{@cap1_stable}']", text: "Required"
      end
      assert_no_selector "#assessment-term-weight-#{@cap2_stable}"
      assert_no_selector "#assessment-term-required-#{@cap2_stable}"
      assert_no_selector "#assessment-term-weight-#{@cap3_stable}"

      # The rating stream re-renders the name row with the same view, so the
      # chips must survive a rating rather than vanish with the first click.
      click_rating_frequency("#rating-#{@cap1_stable}-2", "Consistently")
      assert_selector "#capability-name-#{@cap1_stable} [data-capability-score]", text: /\d+%/
      assert_selector "button[aria-describedby='assessment-term-weight-#{@cap1_stable}']", text: "×2"
      assert_selector "button[aria-describedby='assessment-term-required-#{@cap1_stable}']", text: "Required"
    end

    # #485: an unrated capability scored 0 and blocked like a "not yet", so a
    # fresh assessment wore Blocked beside "Not rated" on every card.
    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "show Not rated, never Blocked, until a rating says so (#{label})" do
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_selector "#scoring-panel"
        assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

        [ @cap1_stable, @cap3_stable ].each do |stable_id|
          assert_selector "#capability-name-#{stable_id} [data-capability-score]", text: "Not rated"
        end
        assert_no_selector "[id^='assessment-term-blocked-']", visible: :all

        click_rating_frequency("#rating-#{@cap3_stable}-2", "Not yet")
        assert_selector "button[aria-describedby='assessment-term-blocked-#{@cap3_stable}']", text: "Blocked"
        assert_no_selector "#assessment-term-blocked-#{@cap1_stable}", visible: :all
      end
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
      # A rating gives the second category a score, so the contrast check below has one to measure
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap3_stable, level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
        )
      end
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

      # The chip went active in the browser, so its score must follow aria-current, not the server.
      assert_selector "nav#category-tabs a[aria-current='page'] span.font-mono", text: "%"
      assert_operator rendered_contrast("nav#category-tabs a[aria-current='page'] span.font-mono"), :>=, 4.5
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

      # Smooth scroll + category_nav's 600ms settle pass + the CSS
      # scroll-driven hero collapse all need to land before the offset
      # measurement is meaningful. Poll until the section settles
      # within tolerance instead of using a fixed sleep — bounded by
      # Capybara's default wait so a true regression still fails fast.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                 Capybara.default_max_wait_time
      offset = nil
      loop do
        offset = page.evaluate_script(
          "(function() { var s = document.getElementById('category-#{@cat2_id}'); " \
          "var h = document.getElementById('assessment-sticky-header'); " \
          "return s.getBoundingClientRect().top - (h.getBoundingClientRect().bottom); })()"
        )
        break if offset.between?(-5, 30)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.1
      end

      # The second category section should land at or just below the
      # bottom of the sticky header — not under it, not far below.
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
      sleep 0.6
      # Then iterate until cat2's section sits a few px inside the
      # active-detection threshold (header bottom). Re-measuring on each
      # pass absorbs any layout shift caused by the hero's scroll-driven
      # collapse — we want a stable end state, not a one-shot scroll.
      5.times do
        page.execute_script(<<~JS)
          var s = document.getElementById('category-#{@cat2_id}');
          var h = document.getElementById('assessment-sticky-header');
          var target = s.getBoundingClientRect().top + window.scrollY - h.offsetHeight - 4;
          window.scrollTo(0, target);
        JS
        sleep 0.4
      end

      # Poll for aria-current to land — the category-nav controller
      # updates aria-current on scroll (RAF-coalesced), and its
      # _suppressActiveUpdateUntil window can briefly defer the update
      # after the synthetic scrollTo bursts above. Bound by Capybara's
      # default wait so a true regression still fails fast.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                 Capybara.default_max_wait_time
      active = false
      loop do
        active = page.evaluate_script(
          "(function() { var c = document.querySelector('nav#category-tabs [data-category-id=\"#{@cat2_id}\"]'); " \
          "return c && c.getAttribute('aria-current') === 'page'; })()"
        )
        break if active
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.1
      end
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

    should "show a category's state dot on its chip only once its score unlocks" do
      # The chip carries the category's state as a dot and its percent —
      # both behind the same coverage gate as the header, so an untouched
      # category shows its name and count without a misleadingly low score.
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap1_stable,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
        )
      end

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within("nav#category-tabs a[data-category-id='#{@cat_id}']") do
        assert_selector "[data-category-status]"
        assert_text "%"
      end
      # "Delivering" has an E2 cell nobody has rated — gated, so no dot.
      within("nav#category-tabs a[data-category-id='#{@cat2_id}']") do
        assert_no_selector "[data-category-status]"
        assert_no_text "%"
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
      prepare_chip_scroll(from: 1200)

      # JS-dispatch so Capybara doesn't scroll the chip into view for us.
      page.execute_script("document.getElementById('cell-#{@cap2_stable}-1').click()")

      # The eyebrow ("THINKING") and capability name ("Problem Solving")
      # must be in view, not pushed under the sticky chrome.
      assert_card_settles(@cap2_stable, "sit at or below the effective sticky chrome") { |offset| offset >= -5 }
    end

    should "smooth scroll the capability card into view when a chip is clicked" do
      # From scrollY=0 the header is expanded and cap2 (Problem Solving) is
      # below the fold, so the hero collapses mid-scroll and moves the target
      # — the race the post-scroll settle pass exists for.
      prepare_chip_scroll(from: 0)

      page.execute_script("document.getElementById('cell-#{@cap2_stable}-1').click()")

      # Close enough below the chrome that the eyebrow and name show without
      # scrolling up: the card's scroll-margin leaves a 12px gap.
      assert_card_settles(@cap2_stable, "land 0-30px below the effective sticky chrome") { |offset| offset.between?(0, 30) }
    end

    # A chip click swaps that one card (#488): the matrix and the other cards
    # are the same DOM nodes afterwards, and every card keeps its own level.
    should "swap only the clicked card, keep each card's level, and survive a reload" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      # The page's inline matrix is replaced once the frame's own load lands.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "matrix"
      page.execute_script(<<~JS)
        window.__matrixRoot = document.querySelector("[data-controller~='matrix'][data-matrix-card-url-value]");
        window.__otherCard = document.getElementById("capability-card-#{@cap2_stable}");
      JS

      click_selector_with_js_fallback("#cell-#{@cap1_stable}-1", expect_text: "Asks clarifying questions to understand problems")
      assert_no_text "Synthesises information from multiple sources"
      assert page.evaluate_script("window.__matrixRoot.isConnected && window.__otherCard.isConnected"),
        "the matrix and the other cards must not be re-rendered"
      assert_selector "#capability-card-#{@cap1_stable}[data-focused='true']"

      click_selector_with_js_fallback("#cell-#{@cap3_stable}-1", expect_text: "Delivers small tasks reliably")
      assert_text "Asks clarifying questions to understand problems"
      assert_selector "#capability-card-#{@cap3_stable}[data-focused='true']"
      assert_selector "[data-focused='true'][data-matrix-target='card']", count: 1
      assert page.evaluate_script("window.__matrixRoot.isConnected")
      assert_includes page.current_url, CGI.escape("levels[#{@cap1_stable}]") + "=1"

      page.execute_script("window.__beforeReload = true")
      visit page.current_url
      assert page.evaluate_script("window.__beforeReload !== true"), "the page must actually reload"
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      assert_text "Asks clarifying questions to understand problems"
      assert_text "Delivers small tasks reliably"
    end

    should "swap the clicked card on a phone too" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      # The page's inline matrix is replaced once the frame's own load lands.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "matrix"
      page.execute_script(<<~JS)
        window.__matrixRoot = document.querySelector("[data-controller~='matrix'][data-matrix-card-url-value]");
      JS

      click_selector_with_js_fallback("#cell-#{@cap3_stable}-1", expect_text: "Delivers small tasks reliably")
      assert_no_text "Owns medium-scope features end-to-end"
      assert page.evaluate_script("window.__matrixRoot.isConnected")
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
    should "tint unrated below-level chips with assumed-consistent blue" do
      visit assessment_path(@assignment)
      # The unrated E1 chip (below person_level=2) should carry the
      # assumed-consistent tint — the person is at E2, so we assume
      # they've cleared E1. "Consistently" is blue in the palette, so
      # the assumed-consistent fill is a clearly-blue tint.
      chip_classes = page.evaluate_script(
        "document.getElementById('cell-#{@cap1_stable}-1').className"
      )
      assert_match(/bg-rating-consistent-assumed/, chip_classes,
        "Unrated below-level chip should carry assumed-consistent blue tint. Classes: #{chip_classes}")
    end

    should "label the person's own current level YOU in self context" do
      visit assessment_path(@assignment)
      within("#cell-#{@cap1_stable}-2") do
        assert_text "YOU"
      end
    end

    should "leave the at-person-level unrated chip neutral grey" do
      visit assessment_path(@assignment)
      # E2 is the person's level; with no rating it should be grey,
      # not tinted (only BELOW-level cells get the light-blue
      # assumed-consistent tint).
      chip_classes = page.evaluate_script(
        "document.getElementById('cell-#{@cap1_stable}-2').className"
      )
      assert_match(/bg-neutral-subtle/, chip_classes,
        "Unrated at-person-level chip should be neutral grey. Classes: #{chip_classes}")
      assert_no_match(/bg-rating-consistent-assumed/, chip_classes,
        "Unrated at-person-level chip must NOT get the below-level blue tint. Classes: #{chip_classes}")
    end

    # Regression: the button-reset utilities added when chips were
    # promoted from <div> to <button> (`bg-transparent`) won the cascade
    # against `bg-blue-300` / `bg-gray-100` / etc — the class string
    # still listed the chip colour but the computed background painted
    # transparent. The existing tests assert on className only and so
    # passed; this asserts on what actually paints.
    should "actually paint a non-transparent background for each chip state" do
      visit assessment_path(@assignment)
      bg = ->(id) { page.evaluate_script("window.getComputedStyle(document.getElementById('#{id}')).backgroundColor") }

      below_unrated = bg.call("cell-#{@cap1_stable}-1")  # E1, below person_level
      at_unrated    = bg.call("cell-#{@cap1_stable}-2")  # E2, person's level

      assert_no_match(/rgba?\(0,\s*0,\s*0,\s*0\)|transparent/i, below_unrated,
        "Unrated below-level chip painted transparent — bg-blue-* lost the cascade. Got: #{below_unrated}")
      assert_no_match(/rgba?\(0,\s*0,\s*0,\s*0\)|transparent/i, at_unrated,
        "Unrated at-level chip painted transparent — bg-gray-* lost the cascade. Got: #{at_unrated}")
    end
  end

  context "scroll stability on rating" do
    should "not jump scroll position when a rating is submitted" do
      # ?capability= focuses the third (Execution) card so the
      # expansion panel renders the rating pill.
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
      # Turbo Stream replacement of the rating cell can momentarily
      # nudge layout while it lands; on slow CI the post-replacement
      # reflow takes longer. Wait for the position to actually settle
      # (two identical samples 100ms apart) instead of sampling at a
      # fixed time.
      stable = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                 Capybara.default_max_wait_time
      loop do
        a = page.evaluate_script("window.scrollY")
        sleep 0.1
        b = page.evaluate_script("window.scrollY")
        if a == b
          stable = b
          break
        end
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end
      scroll_after = stable || page.evaluate_script("window.scrollY")

      # 150px tolerance: the rating turbo-stream replacement re-renders
      # the cell + scoring panel, which can shift surrounding layout by
      # ~one card row on CI. This test is checking for a runaway scroll
      # jump (e.g. to top), not pixel-perfect stability.
      assert_in_delta scroll_before, scroll_after, 150,
        "Scroll should remain stable when rating (was #{scroll_before}, now #{scroll_after})"
    end

    # Regression guard for the hero-collapse "shake": the band collapses on
    # scroll via a scroll-driven animation while it lives inside the in-flow
    # sticky header, which couples scroll position to the animation (via
    # browser scroll-anchoring AND scroll-range clamping on short pages) and
    # makes the band jitter near full visibility. The fix lives on
    # `.assessment-scroll-root` — `overflow-anchor: none` plus a `min-height`
    # floor — gated on scroll-driven-animation support. See
    # app/assets/tailwind/application.css and docs/guidelines/assessments.md.
    should "apply the anti-shake CSS to the assessment scroll root" do
      rate_to_unlock_hero
      visit assessment_path(@assignment)
      assert_selector ".assessment-scroll-root"
      # The collapsible band only exists once coverage unlocks the scoring hero.
      assert_selector ".hero-collapsible", visible: :all

      anchor = page.evaluate_script(
        "getComputedStyle(document.querySelector('.assessment-scroll-root')).overflowAnchor"
      )
      min_h = page.evaluate_script(
        "parseFloat(getComputedStyle(document.querySelector('.assessment-scroll-root')).minHeight)"
      )
      inner_h = page.evaluate_script("window.innerHeight")

      assert_equal "none", anchor,
        "scroll anchoring must be disabled so the collapsing band can't re-drive scroll"
      # Floor = collapse range (240px) + headroom for the band height, on top
      # of the viewport — so a short page's scroll length stays clamp-free.
      assert_operator min_h, :>=, inner_h + 240,
        "min-height floor (#{min_h}px) must exceed the viewport by at least the 240px collapse range"
    end
  end

  context "contrast (WCAG 1.4.3 / 1.4.11)" do
    should "keep the All chip's count at AA while a category chip is active" do
      visit assessment_path(@assignment)
      assert_selector "#category-tabs a[aria-current='page']"

      assert_operator rendered_contrast("#category-tabs [data-all-chip] span"), :>=, 4.5
    end

    should "recolour a chip's percent and count once it is no longer current" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap1_stable,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
        )
      end
      visit assessment_path(@assignment)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "category-nav"
      old_chip = "nav#category-tabs a[data-category-id='#{@cat_id}']"
      assert_selector "#{old_chip}[aria-current='page']"

      page.execute_script("document.querySelector(\"nav#category-tabs [data-category-id='#{@cat2_id}']\").click()")
      assert_selector "nav#category-tabs a[data-category-id='#{@cat2_id}'][aria-current='page']"
      assert_no_selector "#{old_chip}[aria-current]"

      # The dot is the first span, then the percent, then the count.
      assert_operator rendered_contrast("#{old_chip} > span:nth-of-type(2)"), :>=, 4.5
      assert_operator rendered_contrast("#{old_chip} > span:nth-of-type(3)"), :>=, 4.5
    end

    should "keep the activity pane's pressed filters at AA in dark mode" do
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ]
      )
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      assert_selector "[data-activity-feed-filter-param='all'][aria-pressed='true']", visible: true

      assert_operator rendered_contrast("[data-activity-feed-filter-param='all'][aria-pressed='true']"), :>=, 4.5
      assert_operator rendered_contrast("[data-activity-feed-mode-param][aria-pressed='true']"), :>=, 4.5
    ensure
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
      )
    end

    should "keep the feedback actions glyph above the 3:1 icon floor" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap1_stable, level_ordinal: 2, source: "self",
          evidence_type: "project_outcome", title: "Launch", content: "Shipped the launch.",
          author_id: @person.id, valence: "demonstrated"
        )
      end
      visit assessment_path(@assignment)
      # The frame's load replaces the cards; a kebab focused before it lands
      # is gone by the time the contrast is read.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      assert_selector "[aria-label='Feedback / evidence actions']", minimum: 2, visible: :all

      # Two share the label: the list header's, and the card's, which only
      # shows on hover or focus.
      assert_operator rendered_contrast("#evidence-list-#{@cap1_stable}-2 > div [aria-label='Feedback / evidence actions']"), :>=, 3
      card_kebab = ".absolute.top-1.right-1 [aria-label='Feedback / evidence actions']"
      page.execute_script("document.querySelector(arguments[0]).focus()", card_kebab)
      assert_selector "#{card_kebab}:focus", visible: :all
      assert_operator rendered_contrast(card_kebab), :>=, 3
    end
  end

  context "target size (WCAG 2.5.8)" do
    setup do
      # The unlocked hero shows "How is this calculated?"; feedback on the
      # card renders its "Discuss".
      rate_to_unlock_hero
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap1_stable, level_ordinal: 2, source: "self",
          evidence_type: "project_outcome", title: "Launch", content: "Shipped the launch.",
          author_id: @person.id, valence: "demonstrated"
        )
      end
    end

    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "give every control at least a 24px target on #{label}" do
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_text "How is this calculated?"
        assert_selector "summary", text: "Discuss"
        wait_for_stimulus "activity-pane"
        toggle_activity_pane
        assert_selector "[data-activity-feed-mode-param]", visible: true

        assert_empty undersized_targets
      end
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

    # WCAG 1.4.12: a two-line clamp cut every description on a phone, and
    # nothing revealed the rest (#320). The whole description must render.
    should "show a capability's full description on mobile, even with text-spacing overrides" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.update_capability(
          @framework_id, @cap1_id,
          description: "Considers long-term impact, balances competing priorities, and makes smart, " \
                       "intentional decisions that support our mission and the people we serve."
        )
      end
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment)
      assert_text "the people we serve."

      clipped = page.evaluate_script(<<~JS)
        (() => {
          const style = document.createElement("style");
          style.textContent = "* { line-height: 1.5 !important; letter-spacing: 0.12em !important; " +
                              "word-spacing: 0.16em !important; } p { margin-bottom: 2em !important; }";
          document.head.appendChild(style);
          const p = [...document.querySelectorAll("p")].find(e => e.textContent.includes("the people we serve."));
          const cut = p.scrollHeight > p.clientHeight + 1;
          style.remove();
          return cut;
        })()
      JS
      assert_not clipped, "the capability description is cut off"
    end

    # WCAG 1.4.10: the page reflows at 320 CSS px. "Most of the time" is the
    # widest pill phrase, and "Demonstrates:" used to be glued to it with
    # nowrap, so the pair pushed the whole page sideways (#319).
    [ [ "320px", [ 320, 812 ] ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "not scroll the page sideways at #{label}" do
        rate_to_unlock_hero(frequency: "occasional")
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_selector "#rating-#{@cap1_stable}-2", text: "Most of the time"

        assert_no_sideways_overflow("the page scrolls sideways at #{label}")
      end
    end

    # A Kit::Button's 44px hit area must not reach a neighbour's face. The
    # sticky header's buttons reached the card chips scrolling up beneath it,
    # which needs the narrower main column the open activity pane leaves.
    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "give every tap to the control under it at #{label}" do
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_text "Synthesises information from multiple sources"
        assert_selector "button[data-activity-pane-target='toggle']"

        toggle_activity_pane if label == "desktop"
        [ 0, 150, 300, 450, 600, 900 ].each do |y|
          page.execute_script("window.scrollTo(0, #{y})")
          assert_no_stolen_taps("scrolled to #{y} at #{label}")
        end
      end
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
      # On CI the CSS scroll-driven hero collapse can transiently nudge
      # the scroll position downward by ~50px before settling. Wait for
      # it to actually settle — poll until scrollY stabilises across
      # two consecutive samples 100ms apart — instead of sampling once
      # mid-animation.
      stable = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                 Capybara.default_max_wait_time
      loop do
        a = page.evaluate_script("window.scrollY")
        sleep 0.1
        b = page.evaluate_script("window.scrollY")
        if a == b
          stable = b
          break
        end
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end

      visible_y = page.evaluate_script(
        "document.getElementById('#{below_hero_id}').getBoundingClientRect().top"
      )
      scroll_y = stable || page.evaluate_script("window.scrollY")

      # After the scroll + compact, the user's scroll position should
      # NOT have snapped back to (or near) zero. On CI the browser
      # repositions partway during the CSS scroll-driven hero collapse
      # (preserving the visual content position as doc height shrinks)
      # — scrollY=36 is the deterministic steady state from a 90px input
      # there, vs ~90 locally. The test is checking "didn't jump to
      # TOP", so the >20 threshold catches the real regression (a true
      # snap-to-zero) without false-positive flagging the CI-specific
      # partial reposition.
      assert scroll_y > 20,
        "Slow scroll past compact threshold caused scroll to jump to top (scrollY=#{scroll_y})"
      # And the visible content below the hero should remain in view.
      assert visible_y < 600,
        "Content below the hero should still be visible after compact (top=#{visible_y})"
    end

    should "collapse the middle band while keeping the hero header visible on scroll" do
      # The middle band only renders in the unlocked scoring hero — rate one
      # current-level cap to clear the 50% coverage threshold.
      rate_to_unlock_hero

      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      # Pre-condition: the file-level fixture must produce a hero with a
      # middle band (the perspective-driven 3-capability list). The band
      # only renders when `primary_scoring[:capability_scores]` holds a
      # scorable capability; with the shared setup (capabilities + ratings)
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
      # rating pill for the person's level (level 2 here).
      visit assessment_path(@assignment, capability: @cap1_stable)

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
      # rating pill for the person's level (level 2 here).
      visit assessment_path(@assignment, capability: @cap1_stable)
      assert_selector "#scoring-panel"

      # Rate level 2 of first capability
      click_rating_frequency("#rating-#{@cap1_stable}-2", "Consistently")

      # The chip color should update to reflect the new rating
      # ("Consistently" is blue-500 in the FrequencyPalette).
      assert_selector "#cell-#{@cap1_stable}-2.bg-rating-consistent", wait: 5
    end

    should "not jump scroll position when scrolling past the hero summary" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )
      page.execute_script("window.scrollTo(0, 600)")
      # CI's headless Chrome is slower to settle the CSS scroll-driven
      # hero collapse than the dev machine — wait long enough that the
      # initial collapse-induced position adjustment is finished before
      # we sample, so the in-delta check measures the steady state.
      sleep 0.8

      pos_before = page.evaluate_script("window.scrollY")
      sleep 0.5
      pos_after = page.evaluate_script("window.scrollY")

      # 30px tolerance: on CI the hero animation can shift the document
      # height by a handful of pixels even after the explicit settle
      # window above. We're testing for a runaway feedback LOOP, not
      # frame-perfect stability — anything within ~one card padding is
      # not a regression.
      assert_in_delta pos_before, pos_after, 30,
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

    should "remember each capability's selected level when another capability's level is selected" do
      visit assessment_path(@assignment)
      assert_text "Critical Thinking"
      wait_for_stimulus "matrix"

      # Baseline: every card auto-focuses the person's level (E2). Cap1's
      # E2 expectation is shown.
      assert_text "Synthesises information from multiple sources"

      # Select E1 on cap1 — its expansion now shows the E1 expectation.
      # JS-dispatched click so the Stimulus action fires reliably on
      # starved CI (see testing.md — *Flake-Prone Click Guards*).
      page.execute_script("document.getElementById('cell-#{@cap1_stable}-1').click()")
      assert_text "Asks clarifying questions to understand problems", wait: 5
      assert_no_text "Synthesises information from multiple sources"

      # Select E1 on cap3 (a different capability). This reloads the whole
      # matrix frame — which previously reset every other card back to the
      # default level. Cap3 now shows its E1 expectation.
      page.execute_script("document.getElementById('cell-#{@cap3_stable}-1').click()")
      assert_text "Delivers small tasks reliably", wait: 5

      # Cap1 must STILL show its chosen E1 level — not snap back to E2.
      assert_text "Asks clarifying questions to understand problems"
      assert_no_text "Synthesises information from multiple sources"

      # And the per-capability selection is URL-driven, so it survives a
      # full reload (shareable / broadcast-resilient): cap1 stays E1, cap3
      # stays E1.
      page.refresh
      assert_text "Critical Thinking"
      wait_for_stimulus "matrix"
      assert_text "Asks clarifying questions to understand problems"
      assert_text "Delivers small tasks reliably"
      assert_no_text "Synthesises information from multiple sources"
    end
  end

  context "carried-forward ratings" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap1_stable,
          level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id,
          comment: "Seeded from prior cycle", source: "seeded",
          seeded_from_cycle_id: SecureRandom.uuid_v7
        )
      end
    end

    should "render the carried pill distinctly and confirm on same-value pick" do
      visit assessment_path(@assignment, capability: @cap1_stable)

      # Carried treatment: the pill trigger carries the data-carried marker;
      # the popover explains the provenance.
      assert_selector "#rating-#{@cap1_stable}-2 [data-carried='true']"
      open_pill_popover("#rating-#{@cap1_stable}-2")
      assert_text "Carried from your last cycle"

      # Picking the SAME value confirms: the rating survives and the pill
      # solidifies (data-carried marker gone).
      click_rating_frequency("#rating-#{@cap1_stable}-2", "Most of the time")
      assert_no_selector "#rating-#{@cap1_stable}-2 [data-carried='true']"

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
          capability_stable_id: @cap1_stable, level_ordinal: 2)
        assert_equal "occasional", rating.self_rated_frequency
        assert_equal "human", rating.self_rating_source
      end
    end

    # #480: the dashed outline was the only signal; people thought they were done.
    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "say To confirm on the card and pill, and confirm with Keep (#{label})" do
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment, capability: @cap1_stable)

        assert_selector "#capability-name-#{@cap1_stable}", text: "To confirm"
        assert_selector "#rating-#{@cap1_stable}-2 [data-carried='true']", text: "confirm"

        open_pill_popover("#rating-#{@cap1_stable}-2")
        page.execute_script(<<~JS)
          const keep = Array.from(document.querySelectorAll("#rating-#{@cap1_stable}-2 [role='menuitem']"))
            .find((item) => item.textContent.startsWith("Keep"));
          keep.closest("form").requestSubmit(keep);
        JS

        assert_no_selector "#capability-name-#{@cap1_stable}", text: "To confirm"
        assert_no_selector "#rating-#{@cap1_stable}-2 [data-carried='true']"
        ActsAsTenant.with_tenant(@tenant) do
          assert_equal "human", AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
            capability_stable_id: @cap1_stable, level_ordinal: 2).self_rating_source
        end
      end
    end

    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "confirm a category's carried ratings from its review page (#{label})" do
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment, capability: @cap1_stable)
        assert_selector "#category-indicators-#{@cat_id}", text: "Confirm 1 carried"

        click_link_with_js_fallback("Confirm 1 carried", expect_text: "Confirm carried ratings · Thinking")
        assert_selector "input[name='cells[]'][value='#{@cap1_stable}|2']:checked"

        click_button_with_js_fallback("Confirm ticked ratings", expect_text: "Confirmed 1 carried rating for this cycle.")
        assert_no_selector "#capability-name-#{@cap1_stable}", text: "To confirm"
        assert_no_selector "#category-indicators-#{@cat_id}", text: "Confirm 1 carried"
      end
    end

    should "render the carried treatment and confirm on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment, capability: @cap1_stable)

      assert_selector "#rating-#{@cap1_stable}-2 [data-carried='true']"
      open_pill_popover("#rating-#{@cap1_stable}-2")
      assert_text "Carried from your last cycle"

      click_rating_frequency("#rating-#{@cap1_stable}-2", "Most of the time")
      assert_no_selector "#rating-#{@cap1_stable}-2 [data-carried='true']"

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
          capability_stable_id: @cap1_stable, level_ordinal: 2)
        assert_equal "human", rating.self_rating_source
      end
    end

    should "clear a carried rating via the explicit Clear rating action" do
      visit assessment_path(@assignment, capability: @cap1_stable)

      # The popover's Clear posts an explicit clear marker — on a carried
      # value a same-frequency POST would otherwise mean confirm.
      open_pill_popover("#rating-#{@cap1_stable}-2")
      page.execute_script(<<~JS, "#rating-#{@cap1_stable}-2")
        const wrapper = document.querySelector(arguments[0]);
        const items = Array.from(wrapper.querySelectorAll('[role="menuitem"]'));
        const clear = items.find(b => b.textContent.includes("Clear rating"));
        clear.closest("form").requestSubmit(clear);
      JS
      assert_selector "#rating-#{@cap1_stable}-2 button[aria-haspopup='menu']", text: "Not rated"

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
          capability_stable_id: @cap1_stable, level_ordinal: 2)
        assert_nil rating.self_rated_frequency
        # The clear leaves the side human-OWNED (empty by choice) so a seed
        # re-run can't resurrect the carried value.
        assert_equal "human", rating.self_rating_source
      end
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

  context "status pill" do
    should "flip from In Progress to Ready for alignment when the last current-level cell is rated" do
      # Pre-rate cap1 at E2 so only cap3 (the other E2-bound capability) is
      # left — cap2 has no level-2 cell and doesn't count toward coverage.
      rate_to_unlock_hero

      visit assessment_path(@assignment)
      assert_selector "#assessment-status-pill"
      within("#assessment-status-pill") { assert_text "In Progress" }

      # Rate the remaining current-level capability via the UI. The header
      # pill lives outside the matrix frame, so it must update live via the
      # rating controller's Turbo Stream — no page reload.
      click_rating_frequency("#rating-#{@cap3_stable}-2", "Consistently")

      within("#assessment-status-pill") do
        assert_text "Ready for alignment"
        assert_no_text "In Progress"
      end
    end

    should "tell a finished assessee they are ready for alignment on the list and the home card" do
      rate_to_unlock_hero
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, @cap3_stable, level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
        )
      end

      visit assessments_path
      assert_text "My Assessments"
      assert_text "Ready for alignment"
      assert_text "Review self-assessment"

      visit root_path
      assert_current_path root_path
      home_card = "turbo-frame[id^='home-card-assessment_progress-']"
      assert_selector home_card, text: "Ready for alignment"
      assert_selector home_card, text: "Review self-assessment"
      click_link_with_js_fallback("Review self-assessment", expect_selector: "#assessment-status-pill")
      within("#assessment-status-pill") { assert_text "Ready for alignment" }
    end
  end

  context "the lowest rating" do
    # "Not yet", never "None"/"Never" (issue #391) — on the popover option,
    # the pill, the chip's accessible name and the live-status announcement.
    # Both viewports: the pill sits in the expectation sentence, which wraps
    # differently at 375px.
    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |name, size|
      should "read Not yet on every surface (#{name})" do
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

        # The helper itself asserts the popover option and the pill trigger
        # both read "Not yet"; what's left is the chip's accessible name and
        # the announcement.
        click_rating_frequency("#rating-#{@cap1_stable}-2", "Not yet")

        # Composed after "rated", a bare "not yet" would read as "not yet
        # rated" — the opposite state — so both carry the spoken form.
        assert_selector "#cell-#{@cap1_stable}-2[aria-label*='rated not yet demonstrated']"
        assert_selector "#assessment-live-status",
          text: "Rated not yet demonstrated — Critical Thinking, E2", visible: :all
      end
    end
  end

  context "a category header's description" do
    # Reported from the field (#413): sharing the header's one row with the
    # score cluster squeezed a real description into a four-word ribbon six
    # lines tall — inside a sticky header, so it ate the viewport it was
    # pinned to. The description now owns a row of its own beneath the name.
    LONG_DESCRIPTION = "Domain-specific technical knowledge and skills required for the engineering " \
                       "discipline. Strength in one technical area can compensate for a gap in " \
                       "another, but the group must not go negative overall."

    # `max-w-3xl` caps the description's line length, so on a wide screen a
    # squeezed column can still be wider than the cap — geometry alone can't
    # tell the two layouts apart there. Two assertions, each biting where the
    # other can't: the row it lives in (any width) and the width it gets
    # (narrow, which is where the ribbon was reported).
    MAX_DESCRIPTION_WIDTH = 768

    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |name, size|
      should "own its row and its width, not a residue beside the score (#{name})" do
        ActsAsTenant.with_tenant(@tenant) do
          FrameworkState::CapabilityCategory.find_by!(category_id: @cat_id)
            .update!(description: LONG_DESCRIPTION)
        end
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
        assert_text "Strength in one technical area"

        metrics = page.evaluate_script(<<~JS)
          (function () {
            var header = document.querySelector('#category-#{@cat_id} [data-section-header]');
            if (!header) return null;
            var heading = header.querySelector('h2');
            var description = header.querySelector('p');
            var score = header.querySelector('[id^="category-indicators-"]');
            if (!heading || !description || !score) return null;
            var h = header.getBoundingClientRect();
            var n = heading.getBoundingClientRect();
            var d = description.getBoundingClientRect();
            var style = getComputedStyle(header);
            return {
              // A row of the header itself, not a column shared with the score.
              descriptionIsOwnRow: description.parentElement === header,
              scoreSharesDescriptionColumn: score.parentElement === description.parentElement,
              descriptionWidth: d.width,
              contentWidth: h.width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
              descriptionStartsAtHeadingEdge: Math.abs(d.left - n.left) <= 1
            };
          })()
        JS

        assert metrics, "expected the category header to render a name, a description and a score"
        assert metrics["descriptionIsOwnRow"],
          "the description is nested beside the score instead of taking its own row"
        assert_not metrics["scoreSharesDescriptionColumn"],
          "the score cluster is back in the description's column"
        assert metrics["descriptionStartsAtHeadingEdge"],
          "the description no longer starts at the heading's left edge"

        # Whatever is left after the cap is the full content width — never a
        # residue of it. Allow a point of sub-pixel rounding.
        expected = [ MAX_DESCRIPTION_WIDTH, metrics["contentWidth"] ].min
        assert_operator metrics["descriptionWidth"], :>=, expected - 1,
          "description is #{metrics['descriptionWidth']}px of an available #{expected}px — squeezed"
      end
    end
  end

  context "the explanation layer" do
    # #414: the number is read by the person it describes, so the
    # explanation lives where the number is — not in a help page.
    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |name, size|
      should "open the calculation drawer on the viewer's own numbers (#{name})" do
        rate_to_unlock_hero(frequency: "consistent")
        page.driver.browser.manage.window.resize_to(*size)
        visit assessment_path(@assignment)
        assert_selector "#scoring-panel"

        assert_no_selector "##{Views::Assessments::ScoreExplainerModal::ID}", visible: true
        click_button_with_js_fallback("How is this calculated?", expect_text: "How it adds up")

        within("##{Views::Assessments::ScoreExplainerModal::ID}") do
          # Their arithmetic first, the rules second.
          assert_text "Shown at E2"
          assert_text "How it adds up"
          assert_text "What doesn't count"
        end

        # The way out must be on screen. A drawer taller than the viewport
        # used to centre and push its own title and × off the top edge,
        # leaving Esc as the only exit and nothing on screen saying so.
        close = find("##{Views::Assessments::ScoreExplainerModal::ID} [aria-label='Close']")
        assert_operator close.rect.y, :>=, 0, "the close button is above the top of the viewport"
        viewport_height = page.evaluate_script("window.innerHeight")
        assert_operator close.rect.y, :<, viewport_height,
          "the close button is below the bottom of the viewport"
      end
    end

    should "define a scored term on hover and on keyboard focus" do
      rate_to_unlock_hero(frequency: "consistent")
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      # The hero renders inline, then its frame's `src` load replaces it. A
      # term found before that swap is detached with its panel, and focusing
      # it opens nothing on screen.
      assert_selector "turbo-frame#assessment-scoring[complete]", visible: :all

      trigger = find("[aria-describedby='assessment-term-score']", match: :first)
      assert_equal "button", trigger.tag_name,
        "the term must be a real focusable control, not a bare span with a title"

      # The panel starts hidden, so asserting its text without focusing first
      # would pass even if focus revealed nothing — which is the whole point
      # of not using `title` here.
      assert_no_selector "#assessment-term-score", visible: true
      wait_for_stimulus "definition-tip"

      # The definition is reachable without a pointer — the assessee may be
      # driving by keyboard, and `title` would be unreachable to them.
      # Focus without scrolling: `send_keys` scrolls the term into view
      # first, and the controller closes an open panel on scroll, so on a
      # slow runner the scroll could land after the focus and hide it again.
      page.execute_script("arguments[0].focus({ preventScroll: true })", trigger)
      assert_selector "#assessment-term-score", visible: true, text: /How much of what E2 expects/
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

  private

  # The matrix frame renders inline and then swaps in its own load. A chip
  # clicked before that load takes the whole-frame path and scrolls only once
  # the frame lands, which a slow worker can push past any fixed sleep (#501).
  def prepare_chip_scroll(from:)
    visit assessment_path(@assignment)
    # Turbo marks the frame complete before it clears busy, and the chip
    # takes the whole-frame path until both have happened.
    assert_selector "turbo-frame#assessment-matrix[complete]:not([busy])", visible: :all
    wait_for_stimulus "matrix"

    page.execute_script(
      "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
    )
    page.execute_script("window.scrollTo(0, #{from})")
    sleep 0.4
  end

  # Asserts the card's top lands where `landed` says, measured below the sticky
  # chrome (the unified header plus the category heading pinned under it),
  # once the scroll has stopped. The click starts a smooth scroll, and a settle
  # pass re-snaps it 600ms later, so a single reading can land mid-flight. This
  # passes only when `landed` holds on two readings at the same scroll
  # position, no sooner than `settle_after` (the settle pass must get its turn).
  def assert_card_settles(stable_id, expectation, settle_after: 1.0, &landed)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deadline = started + Capybara.default_max_wait_time
    previous_scroll_y = nil
    last = nil
    loop do
      # Null while a card swap is mid-render; the next reading finds it.
      reading = page.evaluate_script(<<~JS)
        (function() {
          var card = document.querySelector('[data-capability-stable-id="#{stable_id}"]');
          if (!card) return null;
          var sectionHeader = card.closest("section[data-category-id]")
            ?.querySelector(":scope > [data-section-header]");
          return {
            card_top: card.getBoundingClientRect().top,
            header_bottom: document.getElementById('assessment-sticky-header').getBoundingClientRect().bottom,
            section_header_height: sectionHeader ? sectionHeader.offsetHeight : 0,
            scroll_y: window.scrollY
          };
        })()
      JS
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if reading
        offset = reading["card_top"] - reading["header_bottom"] - reading["section_header_height"]
        last = [ offset, reading ]
        on_target = landed.call(offset)
        return pass if on_target && previous_scroll_y == reading["scroll_y"] && now - started >= settle_after

        previous_scroll_y = on_target ? reading["scroll_y"] : nil
      else
        # A settled pair must be two readings of the same card.
        previous_scroll_y = nil
      end
      break if now > deadline

      sleep 0.25
    end
    flunk "Capability card #{stable_id} never rendered" unless last

    flunk "Capability card top should #{expectation} once scrolling stops " \
          "(offset=#{last[0]}, diagnostics=#{last[1].inspect})"
  end

  # Rates one current-level capability (cap1) so the assessment clears the
  # 50% coverage threshold (1 of 2 E2-bound caps) and the hero swaps from the
  # priming "rate to see your score" prompt to the real scoring hero.
  def rate_to_unlock_hero(frequency: "consistent")
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @framework_id, @cap1_stable,
        level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id
      )
    end
  end

  # Visible controls smaller than 24x24 CSS px. A link inside running text
  # is exempt (2.5.8's inline exception), and a 1px sr-only element is not a
  # visible target at all.
  def undersized_targets
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll("button, a[href], summary, [role=button], [role=link], select, input:not([type=hidden])")]
        .filter(e => e.offsetParent !== null && !e.closest("p"))
        .map(e => [e, e.getBoundingClientRect()])
        .filter(([, r]) => r.width > 1 && r.height > 1 && (r.width < 24 || r.height < 24))
        .map(([e, r]) => `${e.tagName.toLowerCase()} "${(e.innerText || e.getAttribute("aria-label") || "").trim().slice(0, 30)}" ${Math.round(r.width)}x${Math.round(r.height)}`)
    JS
  end
end
