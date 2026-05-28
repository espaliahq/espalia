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
    should "show lift toward CURRENT level when below expectations" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Person is at E2 with no ratings yet → below expectations.
      # The lift column should target the current level (E2), not E3.
      # (Label is CSS-uppercased, so Capybara sees it as "LIFT TOWARD E2".)
      within("#scoring-panel") do
        assert_text "LIFT TOWARD E2"
        assert_no_text "LIFT TOWARD E3"
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
        assert_no_text "Continue assessing"
      end
    end

    should "show Continue assessing button when some current-level cells are unrated" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      within("#scoring-panel") do
        assert_text "Continue assessing"
      end
    end

    should "navigate to the unrated capability when Continue assessing is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      page.execute_script(
        "document.querySelector('a[data-controller~=\"continue-assessing\"]').click()"
      )

      # The matrix turbo frame should reload with the capability + level
      # focus params in its src.
      sleep 0.5
      frame_src = page.evaluate_script(
        "document.querySelector('turbo-frame#assessment-matrix').getAttribute('src')"
      )
      assert_match(/capability=#{@cap1_stable}/, frame_src,
        "Expected matrix frame to reload with capability=#{@cap1_stable}, got #{frame_src}")
      assert_match(/level_ordinal=2/, frame_src,
        "Expected matrix frame to reload with level_ordinal=2, got #{frame_src}")
    end
  end

  context "category navigation" do
    should "scroll the second category section under the sticky header when its chip is clicked" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"
      assert_selector "section#category-#{@cat2_id}"

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

      # Scroll so the second category section is at the top of the viewport
      page.execute_script(<<~JS)
        var s = document.getElementById('category-#{@cat2_id}');
        var h = document.getElementById('assessment-sticky-header');
        window.scrollTo(0, s.offsetTop - h.offsetHeight - 4);
      JS
      sleep 0.8

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

  context "hero refinements" do
    should "not render a context-label eyebrow above the verdict" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within("#scoring-panel") do
        assert_no_text "SELF ASSESSMENT"
        assert_no_text "Self Assessment"
      end
    end

    should "compress the hero when the user scrolls past it" do
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      # Add tall spacer so we can scroll
      page.execute_script(
        "document.querySelector('main').insertAdjacentHTML('beforeend', '<div style=\"height:2000px\"></div>')"
      )

      # Strengths / Lift should be visible at the top
      assert_text "LIFT TOWARD E2"

      # Scroll past the hero
      page.execute_script("window.scrollTo(0, 500)")
      sleep 0.6

      # Strengths / Lift columns should be hidden in compact mode
      lift_visible = page.evaluate_script(
        "(function() { " \
        "var nodes = document.querySelectorAll('#scoring-panel *'); " \
        "for (var i = 0; i < nodes.length; i++) { " \
        "  var t = nodes[i].textContent || ''; " \
        "  if (t.indexOf('LIFT TOWARD') === 0 && nodes[i].offsetParent !== null) return true; " \
        "} return false; })()"
      )
      assert_not lift_visible,
        "Lift column should be hidden once the hero compacts on scroll"
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
    should "display assessment with frequency selectors" do
      visit assessment_path(@assignment)

      assert_selector "h1", text: "Senior Software Engineer"
      assert_text "E2"
      assert_text "Critical Thinking"
      assert_text "Problem Solving"

      # Frequency selector buttons visible in the default rating area
      assert_button "Some"
      assert_button "Most"
      assert_button "Consistently"

      # Hero summary card visible
      assert_selector "#scoring-panel"
      assert_text "Thinking"
    end

    should "rate a capability and see scoring update" do
      visit assessment_path(@assignment)

      # The default rating area shows the FrequencySelector for the person's level.
      # Person is at level 2, so rating-#{stable}-2 is in the default area.
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
      chip = find("nav#category-tabs [data-category-id='#{@cat_id}']")
      chip.click
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

      # Click the E1 chip on the first capability
      chip = find("#cell-#{@cap1_stable}-1")
      chip.click

      # The expansion panel for level 1 should appear with level-1 expectation
      assert_text "Asks clarifying questions to understand problems", wait: 5
    end

    should "update capability contribution when rating a frequency" do
      visit assessment_path(@assignment)
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

    should "show weight badge for weighted capabilities" do
      skip "Deferred: card layout weight display differs from old matrix; needs new card-specific assertion"
      visit assessment_path(@assignment)

      # Critical Thinking has weight 2.0 — should show "2×" badge
      assert_text "2×"
    end

    should "show mandatory indicator for zero-tolerance capabilities" do
      skip "Deferred: card layout does not use td.border-l-3 for mandatory indicator"
      visit assessment_path(@assignment)

      # Critical Thinking has deficit_threshold=0 (via individual_tolerance mapping) and weight=2.0
      # Should show amber left border on the name cell (border-l-amber-400)
      assert_selector "td.border-l-3"
    end

    should "show illustration count and reveal full illustrations on cell focus" do
      skip "Deferred: card layout does not use row expansion accordion for illustration reveal"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Illustration count indicators should be visible on the compact cells
      assert_text "2 examples"
      assert_text "1 example"

      # Expanding the row alone surfaces only dot summaries — full
      # illustrations are reserved for the focused cell. Focus the
      # level-1 cell of the first capability to reveal them.
      expand_matrix_row("#capability-name-#{@cap1_stable}")
      cap1_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap1_id, level_ordinal: 1)

      assert_text "Asks 'why' before jumping into implementation"
      assert_text "Rephrases the problem statement in their own words"
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

  context "row expansion accordion" do
    should "expand a row when clicking it" do
      skip "Deferred: card layout does not use row expansion accordion"
      visit assessment_path(@assignment)

      # Click the capability name cell — avoids hitting rating form buttons
      expand_matrix_row("#capability-name-#{@cap1_stable}")
      assert_selector "[data-matrix-target='expandedRow']", visible: true
    end

    should "keep row expanded when clicking it again" do
      skip "Deferred: card layout does not use row expansion accordion"
      visit assessment_path(@assignment)

      expand_matrix_row("#capability-name-#{@cap1_stable}")

      # Click the same capability name again — should stay expanded
      find("#capability-name-#{@cap1_stable}").click
      assert_selector "[data-matrix-target='expandedRow']", visible: true
    end

    should "collapse expanded row and expand new row when clicking a different row" do
      skip "Deferred: card layout does not use row expansion accordion"
      visit assessment_path(@assignment)

      # Expand first row, then focus a cell so we can assert on the
      # focused-cell-only illustration text as a "this row is expanded
      # AND focused" signal.
      expand_matrix_row("#capability-name-#{@cap1_stable}")
      cap1_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap1_id, level_ordinal: 1)
      assert_text "Asks 'why' before jumping into implementation"

      # Click second row — first should collapse, second should expand.
      # JS-dispatch the click because Capybara's pointer click is dropped
      # on slow CI (and click_with_retry's retry uses the same mechanism).
      page.execute_script("document.querySelector('#capability-name-#{@cap2_stable}').click();")
      cap2_id = capability_id_from_stable(@cap2_stable)
      unless page.has_selector?("[data-matrix-target='expandedRow'][data-capability-id='#{cap2_id}']", visible: true, wait: 8)
        page.execute_script("document.querySelector('#capability-name-#{@cap2_stable}').click();")
      end

      assert_no_selector "[data-matrix-target='expandedRow'][data-capability-id='#{cap1_id}']", visible: true
      assert_selector "[data-matrix-target='expandedRow'][data-capability-id='#{cap2_id}']", visible: true
      assert_no_text "Asks 'why' before jumping into implementation"
    end

    should "collapse row when clicking its chevron" do
      skip "Deferred: card layout does not use row expansion accordion"
      visit assessment_path(@assignment)

      expand_matrix_row("#capability-name-#{@cap1_stable}")

      # Click the chevron to collapse
      row1 = find("[data-matrix-target='row']", match: :first)
      chevron = row1.find("[data-matrix-target='rowChevron']")
      chevron.click
      assert_no_selector "[data-matrix-target='expandedRow']", visible: true
    end

    should "keep illustrations expanded when rating a capability in the same row" do
      skip "Deferred: card layout does not use row expansion accordion"
      visit assessment_path(@assignment)

      # Expand the first row and focus a cell so its illustration is
      # visible — illustrations only render in the focused cell.
      expand_matrix_row("#capability-name-#{@cap1_stable}")
      cap1_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap1_id, level_ordinal: 1)
      assert_text "Asks 'why' before jumping into implementation"

      # Click a rating button inside the same row.
      # Use the capability stable_id to build a precise selector, avoiding
      # stale element references from Turbo Stream replacements.
      click_rating_frequency("#rating-#{@cap1_stable}-1", "Consistently")

      # Row should still be expanded with the same focused cell content visible
      assert_selector "[data-matrix-target='expandedRow']", visible: true
      assert_text "Asks 'why' before jumping into implementation"
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

    context "at mobile viewport" do
      setup do
        page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      end

      should "display category tabs and default to first category" do
        skip "Deferred: card layout uses always-visible category chip bar, not mobile-only tabs"
        visit assessment_path(@assignment)

        # Both tabs should be visible
        assert_selector "#category-tabs"
        assert_text "Thinking"
        assert_text "Delivering"

        # First category content should be visible
        assert_text "Critical Thinking"
        assert_text "Problem Solving"

        # Second category content should NOT be visible (only one category rendered)
        assert_no_text "Execution"
      end

      should "switch categories when clicking a tab" do
        skip "Deferred: card layout renders all categories on one scrollable page, not tab-switching"
        visit assessment_path(@assignment)

        # Wait for the lazy-loaded matrix frame to finish its eager fetch.
        # The category-tabs nav lives INSIDE the assessment-matrix turbo frame,
        # so a click on a tab can race the eager-fetch replacement and be
        # silently dropped on slow CI runners.
        assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

        # Drive the Turbo Frame fetch directly by setting frame.src — bypasses
        # the click event entirely. Capybara's pointer click + JS dispatch
        # have both been dropped on starved CI runners; this is the most
        # reliable way to trigger the frame swap.
        page.execute_script(<<~JS)
          const tab = Array.from(document.querySelectorAll("#category-tabs a"))
            .find(a => a.textContent.trim().includes("Delivering"));
          const frame = document.getElementById("assessment-matrix");
          if (tab && frame) frame.src = tab.href;
        JS

        assert_text "Execution"
        assert_text "Ships features reliably"
        assert_no_selector "#capability-name-#{@cap1_stable}"
      end

      should "show progress counts on tabs" do
        skip "Deferred: card layout uses category chip bar with percentage, not rated/total counts"
        visit assessment_path(@assignment)

        # Tabs should show rated/total counts (0 rated initially)
        within "#category-tabs" do
          assert_text "0/"
        end
      end

      should "update tab progress after rating" do
        skip "Deferred: card layout uses category chip bar with percentage, not rated/total counts"
        visit assessment_path(@assignment)

        # Rate a capability in the first tab
        click_rating_frequency("#rating-#{@cap1_stable}-1", "Consistently")

        # Tab progress should update
        within "#category-tabs" do
          assert_text "1/"
        end
      end
    end

    should "switch tab when clicking category in scoring panel" do
      skip "Deferred: card layout uses anchor-link chips in hero summary, not tab-switching from scoring panel"
      visit assessment_path(@assignment)

      # Wait for the lazy-loaded scoring frame to finish its eager fetch.
      # Without this, clicking inside #scoring-panel can race the frame
      # replacement and the click is silently dropped on slow CI runners.
      assert_selector "turbo-frame#assessment-scoring[complete]", visible: :all

      # Drive the Turbo Frame fetch directly by setting frame.src — bypasses
      # the click event entirely (same as the category-tab test above).
      page.execute_script(<<~JS)
        const link = Array.from(document.querySelectorAll("#scoring-panel a"))
          .find(a => a.textContent.trim().includes("Delivering"));
        const frame = document.getElementById("assessment-matrix");
        if (link && frame) frame.src = link.href;
      JS

      assert_text "Execution"
      assert_no_selector "#capability-name-#{@cap1_stable}"
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

    should "preserve expanded row focus with sibling dimming" do
      skip "Deferred: card layout does not use row expansion with sibling dimming"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Expand a row
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      # Sibling rows should be dimmed
      rows = all("[data-matrix-target='row']")
      dimmed = rows.select { |r| r[:class]&.include?("opacity-40") }
      assert dimmed.any?, "Expected sibling rows to be dimmed when a row is expanded"
    end
  end

  # Reads the inline `style.width` of the matrix `<col>` for the given
  # level ordinal. `evaluate_script` evaluates an expression (not a
  # block), so the lookup is wrapped in an IIFE.
  #
  # @param level_ordinal [Integer] level ordinal whose `<col>` to read
  # @return [String] inline width — "512px" focused, "280px" sibling,
  #   "" when no inline override is set
  def col_width_for(level_ordinal)
    page.evaluate_script(<<~JS)
      (() => {
        const col = document.querySelector(
          `col[data-matrix-target="col"][data-level-ordinal="#{level_ordinal}"]`
        );
        return col ? col.style.width : null;
      })()
    JS
  end

  # Looks up the per-version `data-capability-id` for the expanded row
  # rendered with the given `stable_id`.
  #
  # @param stable_id [String] capability stable_id (UUID)
  # @return [String, nil] the row's per-version `capability_id`, or
  #   nil when no expanded row matches
  def capability_id_from_stable(stable_id)
    page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector(
          `tr[data-matrix-target="expandedRow"][data-capability-stable-id="#{stable_id}"]`
        );
        return row ? row.dataset.capabilityId : null;
      })()
    JS
  end

  # Polls until the matrix `<col>` for the given level has been
  # restored to its 512px focused width. The rating Turbo Stream and
  # the async CurrentAssessment broadcast that triggers the matrix
  # frame reload settle out of order; this helper waits for the focus
  # state to be re-applied after the reload completes.
  #
  # @param level_ordinal [Integer] focused level ordinal
  # @param wait [Integer] seconds to poll before giving up
  # @return [void]
  def wait_for_focus_restored(level_ordinal:, wait: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      width = col_width_for(level_ordinal)
      return if width == "512px"
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  # Returns the rendered width in pixels of the first matrix `<td>` at
  # the given level ordinal. Reads `getBoundingClientRect().width`, so
  # observes ACTUAL layout, not declared style.
  #
  # @param level_ordinal [Integer] level ordinal whose `<td>` to measure
  # @return [Float, nil] rendered width in CSS pixels, or nil when no
  #   matching `<td>` exists
  def rendered_col_width(level_ordinal)
    page.evaluate_script(<<~JS)
      (() => {
        const td = document.querySelector(
          `td[data-level-ordinal="#{level_ordinal}"]`
        );
        return td ? td.getBoundingClientRect().width : null;
      })()
    JS
  end

  # JS-dispatches a click on the expanded `<td>` for the given
  # capability + level. Bypasses Selenium's synthetic pointer hit-test,
  # which is occasionally dropped on starved CI runners.
  #
  # @param capability_id [String] per-version capability_id
  # @param level_ordinal [Integer] target level
  # @return [void]
  def focus_expanded_cell(capability_id:, level_ordinal:)
    page.execute_script(<<~JS, capability_id, level_ordinal.to_s)
      const td = document.querySelector(
        `tr[data-matrix-target="expandedRow"][data-capability-id="${arguments[0]}"] ` +
        `td[data-level-ordinal="${arguments[1]}"]`
      );
      if (td) td.click();
    JS
  end

  context "cell focus" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    end

    should "widen focused column and show close button when an expanded cell is focused" do
      skip "Deferred: card layout does not use column resize or cell focus close button"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      screenshot("01_default_matrix")

      # Defaults: no inline width on level cols.
      assert_equal "", col_width_for(1)
      assert_equal "", col_width_for(2)

      expand_matrix_row("#capability-name-#{@cap1_stable}")
      screenshot("02_row_expanded_no_focus")

      cap_id = capability_id_from_stable(@cap1_stable)
      assert cap_id, "Expected to resolve the per-version capability_id from the expanded row"

      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)

      assert_equal "512px", col_width_for(1), "Focused column should widen (32rem == 512px)"
      assert_equal "280px", col_width_for(2),
        "Sibling columns keep their default width so the FrequencySelector fits on one line"

      # The close button should be visible inside the focused expanded cell.
      assert_selector(
        "tr[data-matrix-target='row'][data-capability-id='#{cap_id}'] " \
        "td[data-level-ordinal='1'] [data-focused-cell-close]",
        visible: true
      )
      screenshot("03_cell_focused")
    end

    should "restore default column widths when the close button is clicked" do
      skip "Deferred: card layout does not use column resize or cell focus close button"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)

      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      assert_equal "512px", col_width_for(1)
      screenshot("01_focused")

      # JS-dispatch close button click for CI determinism.
      page.execute_script(<<~JS, cap_id)
        const btn = document.querySelector(
          `tr[data-matrix-target="row"][data-capability-id="${arguments[0]}"] ` +
          `td[data-level-ordinal="1"] [data-focused-cell-close]`
        );
        if (btn) btn.click();
      JS

      # Use Capybara wait — the close path runs synchronously but we still
      # poll for the post-state to give the URL pushState handler room.
      assert col_width_for(1) == "", "Focused column width should reset"
      assert col_width_for(2) == "", "Sibling column width should reset"
      screenshot("02_after_unfocus")
    end

    should "deep link with capability + level_ordinal arrives focused" do
      skip "Deferred: card layout does not use column resize for deep-link focus"
      visit assessment_path(@assignment, capability: @cap1_stable, level_ordinal: 1)
      wait_for_stimulus "matrix"

      # Row should be pre-expanded
      assert_selector "[data-matrix-target='expandedRow']", visible: true

      # Column should be focus-widened
      assert_equal "512px", col_width_for(1)

      cap_id = capability_id_from_stable(@cap1_stable)
      assert_selector(
        "tr[data-matrix-target='row'][data-capability-id='#{cap_id}'] " \
        "td[data-level-ordinal='1'] [data-focused-cell-close]",
        visible: true
      )
      screenshot("01_deep_linked_focus")
    end

    should "focus the cell when clicking the compact-row expectation text" do
      skip "Deferred: card layout does not use compact-row cell focus with column resize"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Click the compact cell's expectation text — should expand row AND
      # focus the cell, not just expand.
      page.execute_script(<<~JS)
        (() => {
          const td = document.querySelector(`#cell-#{@cap1_stable}-1`);
          const text = td.querySelector("p");
          if (text) text.click();
        })()
      JS

      assert_selector "[data-matrix-target='expandedRow']", visible: true
      assert_equal "512px", col_width_for(1), "Compact-cell click should focus level 1"

      # Regression: URL must carry BOTH `capability` AND `level_ordinal`
      # so a full page reload (or any frame reload that re-runs
      # dispatchInitialFocus from URL params) restores focus. Pre-fix,
      # focusCell only synced level_ordinal; capability was missing,
      # which made the URL un-restorable on reload and led to
      # level_ordinal getting cleaned away on next focus change.
      params = URI.decode_www_form(
        URI.parse(page.evaluate_script("window.location.href")).query.to_s
      ).to_h
      assert_equal @cap1_stable, params["capability"],
        "Compact-cell click must push capability=stable_id to the URL"
      assert_equal "1", params["level_ordinal"],
        "Compact-cell click must push level_ordinal to the URL"
    end

    should "keep focus when clicking a rating button on an already-focused cell" do
      skip "Deferred: card layout does not use column resize cell focus"
      # Regression: previously, clicking a rating button inside a
      # focused cell hit focusCell's "click same cell to toggle off"
      # branch and dropped focus immediately. Toggle-off must only
      # fire on a BACKGROUND click of the same cell. Additionally, the
      # rating Turbo Stream response replaces the compact cell `<td>`,
      # which would otherwise drop the close-button visibility — we
      # re-apply column focus after every Turbo Stream render.
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      assert_equal "512px", col_width_for(1), "Pre-condition: cell is focused"

      # Click "Some" inside the (already-focused) cell. The form posts
      # a Turbo Stream response that replaces the compact cell, so we
      # wait for the rating to land before re-checking focus.
      page.execute_script(<<~JS)
        (() => {
          const cell = document.querySelector(`#cell-#{@cap1_stable}-1`);
          const btn = Array.from(cell.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Some");
          if (btn) btn.click();
        })()
      JS
      assert_selector "#cell-#{@cap1_stable}-1 button.ring-1", text: "Some"

      # The rating triggers an ActionCable broadcast (CurrentAssessment
      # projection) → assessment_sync reloads the matrix frame
      # asynchronously. Poll for focus state to settle.
      wait_for_focus_restored(level_ordinal: 1)

      assert_equal "512px", col_width_for(1),
        "Clicking a rating button should NOT drop focus from an already-focused cell"

      # The close button should still be visible after the Turbo
      # Stream replaced the compact cell — focus state is whole.
      assert_selector(
        "tr[data-matrix-target='row'][data-capability-id='#{cap_id}'] " \
        "td[data-level-ordinal='1'] [data-focused-cell-close]",
        visible: true
      )

      # Click a SECOND rating button to make sure focus persists across
      # multiple rating changes (the user's flow: rate, then change
      # the rating).
      page.execute_script(<<~JS)
        (() => {
          const cell = document.querySelector(`#cell-#{@cap1_stable}-1`);
          const btn = Array.from(cell.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Most");
          if (btn) btn.click();
        })()
      JS
      assert_selector "#cell-#{@cap1_stable}-1 button.ring-1", text: "Most"
      wait_for_focus_restored(level_ordinal: 1)

      assert_equal "512px", col_width_for(1),
        "Focus should still be intact after a second rating change"
      assert_selector(
        "tr[data-matrix-target='row'][data-capability-id='#{cap_id}'] " \
        "td[data-level-ordinal='1'] [data-focused-cell-close]",
        visible: true
      )
    end

    should "not flash indicator badges when rating the focused cell" do
      skip "Deferred: card layout does not use column resize cell focus with indicator badges"
      # Regression: the rating controllers' Turbo Stream response
      # replaces the cell `<td>`. The server-rendered HTML must carry
      # `data-focused="true"` so the new cell paints with indicators
      # hidden (group-data-[focused=true]/assess-cell:hidden). Without
      # the server-side stamp, the browser paints the new cell with
      # badges visible while matrix_controller's MutationObserver
      # waits to re-stamp focus — the user sees "2 examples" reappear.
      #
      # cap1 L1 has 2 illustrations → "2 examples" indicator badge.
      # When the cell is focused, the badge MUST stay hidden. The
      # capability-name cell has its own "2× / 1×" indicators that
      # aren't related — assert against the cell's td directly.
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      expand_matrix_row("#capability-name-#{@cap1_stable}")
      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      assert_equal "512px", col_width_for(1), "Pre-condition: cell is focused"

      # Pre-condition: focused cell's "2 examples" badge is hidden.
      assert_no_selector "#cell-#{@cap1_stable}-1", text: "2 examples"

      # Click "Some" on the focused cell — fires a Turbo Stream that
      # replaces the cell `<td>`.
      page.execute_script(<<~JS)
        (() => {
          const cell = document.querySelector(`#cell-#{@cap1_stable}-1`);
          const btn = Array.from(cell.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Some");
          if (btn) btn.click();
        })()
      JS
      assert_selector "#cell-#{@cap1_stable}-1 button.ring-1", text: "Some"

      # The cell must have `data-focused="true"` after the rating
      # lands. Two failure modes the regression hits:
      # 1. Server doesn't stamp data-focused → first paint shows badges.
      # 2. Server stamps it but omits data-capability-id → matrix_controller's
      #    MutationObserver re-runs applyColumnFocus, doesn't find a
      #    capability match for the new cell, and `delete`s data-focused.
      assert_selector "#cell-#{@cap1_stable}-1[data-focused='true']", visible: :all

      # And no indicator badge text leaks through.
      assert_no_selector "#cell-#{@cap1_stable}-1", text: "2 examples"
    end

    should "keep focus when clicking on content inside an already-focused expanded cell" do
      skip "Deferred: card layout does not use expanded cell focus with column resize"
      # Regression: clicking on the expanded cell's body (expectation
      # text, illustrations, evidence content — anything that isn't a
      # button/link/input) was hitting focusCell's "background click of
      # the same cell → toggle off" branch and dropping focus. Both the
      # compact AND expanded assessment cells now carry
      # `data-bg-unfocus="false"` to opt out of that branch — the ×
      # close button is the canonical unfocus path.
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      assert_equal "512px", col_width_for(1), "Pre-condition: cell is focused"

      # Click on the expanded cell's expectation text — a non-interactive
      # child of the focused `<td>`. Pre-fix, this would have toggled
      # focus off; post-fix it must be a no-op.
      page.execute_script(<<~JS, cap_id)
        const td = document.querySelector(
          `tr[data-matrix-target="expandedRow"][data-capability-id="${arguments[0]}"] ` +
          `td[data-level-ordinal="1"]`
        );
        // Click on a descendant text node's parent — the illustration
        // list or expectation paragraph, whichever the cell has. We use
        // a non-button child so we exercise the background-click path
        // explicitly.
        const target = td.querySelector("p, li, span, div") || td;
        target.click();
      JS

      # Focus must still be on level 1; close button must still be visible.
      assert_equal "512px", col_width_for(1),
        "Clicking inside the focused cell must NOT drop focus"
      assert_selector(
        "tr[data-matrix-target='row'][data-capability-id='#{cap_id}'] " \
        "td[data-level-ordinal='1'] [data-focused-cell-close]",
        visible: true
      )
    end

    should "not reload the matrix frame when the rater clicks their own rating button" do
      visit assessment_path(@assignment)
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

      # Click the "Some" rating button. Person is at level 2, so the
      # default rating area has #rating-#{stable}-2.
      page.execute_script(<<~JS)
        (() => {
          const cell = document.querySelector(`#rating-#{@cap1_stable}-2`);
          const btn = Array.from(cell.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Some");
          if (btn) btn.click();
        })()
      JS
      assert_selector "#rating-#{@cap1_stable}-2 button.ring-1", text: "Some"

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

    should "preserve focus across a full page reload (F5)" do
      skip "Deferred: card layout does not use column resize focus that persists across reload"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      assert_equal "512px", col_width_for(1), "Pre-condition: focused"

      # Capture the URL after focus — pushState should have written
      # capability + level_ordinal.
      current_url = page.evaluate_script("window.location.href")
      url_obj = URI.parse(current_url)
      params = URI.decode_www_form(url_obj.query.to_s).to_h
      assert_equal @cap1_stable, params["capability"],
        "Browser URL should have capability=stable_id after focus"
      assert_equal "1", params["level_ordinal"],
        "Browser URL should have level_ordinal=1 after focus"

      # Full page reload — go to the same URL fresh. This bypasses
      # Turbo Drive entirely.
      page.execute_script("window.location.reload()")
      wait_for_stimulus "matrix"

      # Focus must be re-applied from the URL params after reload.
      assert_equal "512px", col_width_for(1),
        "Focus should be restored after a full page reload — URL has level_ordinal=1"
    end

    should "preserve focus after rating + full page reload" do
      skip "Deferred: card layout does not use column resize focus"
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)

      # Rate the focused cell
      page.execute_script(<<~JS)
        (() => {
          const cell = document.querySelector(`#cell-#{@cap1_stable}-1`);
          const btn = Array.from(cell.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Some");
          if (btn) btn.click();
        })()
      JS
      assert_selector "#cell-#{@cap1_stable}-1 button.ring-1", text: "Some"
      wait_for_focus_restored(level_ordinal: 1)

      # Verify URL still has level_ordinal after rating
      url_after_rating = page.evaluate_script("window.location.href")
      params = URI.decode_www_form(URI.parse(url_after_rating).query.to_s).to_h
      assert_equal "1", params["level_ordinal"],
        "level_ordinal should still be in URL after rating"

      # Full reload — should arrive focused
      page.execute_script("window.location.reload()")
      wait_for_stimulus "matrix"

      assert_equal "512px", col_width_for(1),
        "Focus should survive: rate → reload"
    end

    should "stay reachable on mobile viewport" do
      skip "Deferred: card layout does not use column resize cell focus on mobile"
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)

      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      assert_equal "512px", col_width_for(1)

      # Close button must still be in the DOM and visible at mobile width.
      assert_selector(
        "tr[data-matrix-target='row'][data-capability-id='#{cap_id}'] " \
        "td[data-level-ordinal='1'] [data-focused-cell-close]",
        visible: true
      )
      screenshot("01_mobile_focused")
    end
  end

  context "cell focus with many levels" do
    # Realistic frameworks have 5–8 levels; with `w-full` + `table-fixed`,
    # browsers proportionally scale `<col>` widths down when their sum
    # exceeds the table's container width — silently breaking the
    # focused-column-wider behaviour. This context adds extra levels and
    # asserts ACTUAL rendered widths (getBoundingClientRect) rather than
    # declared style.width, so the test catches the layout issue.
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.start_draft(@framework_id, 2, "test")

        (3..7).each do |ord|
          level_id = SecureRandom.uuid_v7
          handler.add_level(@framework_id, level_id, @role_id, ord, "Level #{ord}", "E#{ord}")
          handler.set_behavioural_expectation(
            @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
            @cap1_id, ord, "Expectation for level #{ord}"
          )
        end
        handler.publish_version(@framework_id, "test")

        # Add an illustration on level 3 after publish so the focus target
        # has content beyond the expectation text.
        handler.add_role_illustration(
          @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
          FrameworkState::BehaviouralExpectation.find_by!(capability_id: @cap1_id, level_ordinal: 3).expectation_id,
          @role_id, 3, "Drives critical decisions in design reviews"
        )
      end
    end

    should "keep columns wide enough for the FrequencySelector in default unfocused state" do
      skip "Deferred: card layout does not use table columns; level strip uses horizontal chips"
      # Regression: with many levels, the unfocused matrix must keep
      # each column wide enough to show the FrequencySelector's four
      # buttons without wrapping. Pre-fix, `w-full` + no col widths
      # divided the matrix area equally and dropped each col below
      # ~140px on realistic frameworks, stacking the buttons.
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      screenshot("01_default_unfocused_many_levels")

      # Each level column should respect the cell's `min-w-[180px]`.
      # We don't focus anything — pure default state.
      width = rendered_col_width(1)
      assert width >= 180,
        "Default unfocused column rendered at #{width}px — expected " \
        "min 180px so FrequencySelector buttons stay on one line"

      # The FrequencySelector container should not wrap — buttons fit
      # horizontally in a single row.
      single_row = page.evaluate_script(<<~JS)
        (() => {
          const cell = document.querySelector(`#cell-#{@cap1_stable}-1`);
          if (!cell) return null;
          const buttons = cell.querySelectorAll("[data-frequency-selector-target='button']");
          if (buttons.length < 2) return null;
          const firstTop = buttons[0].getBoundingClientRect().top;
          // All buttons should share the same baseline (same row)
          return Array.from(buttons).every(b =>
            Math.abs(b.getBoundingClientRect().top - firstTop) < 1
          );
        })()
      JS
      assert_equal true, single_row,
        "FrequencySelector buttons should all sit on one row in the default " \
        "unfocused state (non-wrapped)"
    end

    should "focusing the first level keeps the cell out from behind the sticky capability column" do
      skip "Deferred: card layout does not use sticky capability column or column resize"
      # Regression: scrolling with `inline: "center"` (or "start") parks
      # the focused cell directly under the sticky-left capability
      # column so users see the cap column overlaying their selection.
      # The fix manually scrolls so the focused cell's left edge sits
      # at or past the cap column's right edge.
      page.driver.browser.manage.window.resize_to(1024, 1000)
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 1)
      screenshot("01_focused_first_level")

      # Wait for smooth scroll to settle. Capybara doesn't have a
      # native primitive for scroll completion — poll for stable
      # scrollLeft over 2 frames.
      stable = page.evaluate_script(<<~JS)
        new Promise(resolve => {
          const scroller = document.querySelector(".overflow-x-auto");
          let last = scroller.scrollLeft;
          let stableTicks = 0;
          const check = () => {
            const cur = scroller.scrollLeft;
            if (cur === last) {
              stableTicks++;
              if (stableTicks >= 3) return resolve(true);
            } else {
              stableTicks = 0;
            }
            last = cur;
            requestAnimationFrame(check);
          };
          check();
          setTimeout(() => resolve(true), 2000);
        })
      JS
      assert stable

      positions = page.evaluate_script(<<~JS)
        (() => {
          const compactCell = document.querySelector(
            `tr[data-matrix-target="row"][data-capability-id="#{cap_id}"] td[data-level-ordinal="1"]`
          );
          const capCol = document.querySelector(`col[data-level-ordinal="capability"]`);
          const capCell = document.querySelector(
            `tr[data-matrix-target="row"][data-capability-id="#{cap_id}"] td.sticky`
          ) || document.querySelector(
            `tr[data-matrix-target="row"][data-capability-id="#{cap_id}"] td:first-child`
          );
          return {
            cellLeft: compactCell?.getBoundingClientRect().left,
            cellRight: compactCell?.getBoundingClientRect().right,
            capRight: capCell?.getBoundingClientRect().right
          };
        })()
      JS

      assert positions["cellLeft"] >= positions["capRight"] - 1,
        "Focused cell's left edge (#{positions['cellLeft']}) should be at " \
        "or past the sticky capability column's right edge (#{positions['capRight']}); " \
        "otherwise the cap column overlays the cell"
    end

    should "render focused column visibly wider than siblings with many levels" do
      skip "Deferred: card layout does not use column resize"
      # Use a narrower viewport so the table's container width is closer
      # to the sum of declared col widths — exposes the `w-full` +
      # `table-fixed` proportional-scaling bug. At 1400px (default
      # DESKTOP_SIZE) the matrix area exceeds the col sum and the bug
      # masks itself.
      page.driver.browser.manage.window.resize_to(1024, 1000)
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap_id = capability_id_from_stable(@cap1_stable)
      focus_expanded_cell(capability_id: cap_id, level_ordinal: 3)
      screenshot("01_focused_with_many_levels")

      focused_width = rendered_col_width(3)
      sibling_width = rendered_col_width(5)

      # Bug: with `w-full` + `table-fixed`, browsers proportionally
      # scale the declared widths down when their sum exceeds the
      # table's container width — focused and sibling cols ended up
      # nearly equal in width and focus was visually indistinguishable.
      # Fixed: focused col is 32rem (~512px), siblings keep their
      # default 280px so the FrequencySelector still fits on one line.
      assert focused_width.present?, "Expected to read focused col width"
      assert sibling_width.present?, "Expected to read sibling col width"
      assert focused_width >= sibling_width * 1.7,
        "Focused column (#{focused_width}px) should be at least 1.7× sibling (#{sibling_width}px)"
      assert focused_width >= 480,
        "Focused col rendered #{focused_width}px — expected close to 32rem (≈512px)"
      assert sibling_width >= 270,
        "Sibling col rendered #{sibling_width}px — expected default ≈280px so " \
        "FrequencySelector still fits on a single row"
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
