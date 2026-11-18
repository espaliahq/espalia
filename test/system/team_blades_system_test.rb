# frozen_string_literal: true

require "application_system_test_case"

# A manager's team as one set of capability blades: the card at the head of
# Team Assessments, and the team map it opens, at desktop and phone widths.
class TeamBladesSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Morgan Vale")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @manager)

      @framework_id = SecureRandom.uuid_v7
      FactoryBot.create(:framework_state, framework_id: @framework_id, name: "Engineering Growth")
      family = FactoryBot.create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
      @role = FactoryBot.create(:framework_role, role_family_id: family.role_family_id, name: "Software Engineer",
                                                 code: "E", track: "ic")
      @levels = (1..3).to_h do |ordinal|
        [ ordinal, FactoryBot.create(:framework_level, role_id: @role.role_id, ordinal:, title: "E#{ordinal}", code: "E#{ordinal}") ]
      end
      category = FactoryBot.create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @capabilities = [ "Player coach", "Delivery" ].map do |name|
        capability = FactoryBot.create(:framework_capability, category_id: category.category_id, name:)
        FactoryBot.create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: @role.role_id)
        (1..3).each do |ordinal|
          FactoryBot.create(:framework_behavioural_expectation, capability_id: capability.capability_id, level_ordinal: ordinal)
        end
        capability
      end
      @cycle_id = SecureRandom.uuid_v7
      AssessmentCycles::CommandHandler.new.define_cycle(@cycle_id, @framework_id, "H2 2026 review", "regular", 1)
    end
  end

  # Assigning a report enrols them in the open cycle; the manager then rates each capability.
  def add_report(name, level, *frequencies)
    ActsAsTenant.with_tenant(@tenant) do
      report = FactoryBot.create(:person, tenant: @tenant, name:, manager: @manager)
      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(report.id, @framework_id, @role.role_id, @levels.fetch(level).level_id)
      AssessmentCycles::CommandHandler.new.enroll(@cycle_id, report.id) unless
        AssessmentCycleEnrollment.exists?(cycle_id: @cycle_id, person_id: report.id)
      @capabilities.zip(frequencies).each do |capability, frequency|
        next unless frequency

        handler.rate_as_manager(report.id, @framework_id, capability.stable_id, level_ordinal: level,
                                                                                 frequency:, cycle_id: @cycle_id, rated_by_id: @manager.id)
      end
    end
  end

  # The dialog clips sideways overflow, so a too-wide control is cut off rather than scrolling the page.
  def assert_compare_control_fits
    overhang = evaluate_script(<<~JS)
      (() => {
        const control = document.querySelector("#team-map [aria-labelledby='team-compare-label']")
        let clip = control.parentElement
        while (clip && getComputedStyle(clip).overflowX === "visible") clip = clip.parentElement
        return control.getBoundingClientRect().right - clip.getBoundingClientRect().right
      })()
    JS
    assert_operator overhang, :<=, 0, "expected the Compare with control inside the dialog"
  end

  def open_team_map
    wait_for_stimulus "modal", scope: "#team-card"
    click_button_with_js_fallback("Open team map", expect_text: "Your 3 direct reports, manager ratings")
  end

  def visit_team(size)
    page.driver.browser.manage.window.resize_to(*size)
    sign_in_as(@user)
    visit assessments_path
    assert_selector "#team-card", text: "Your team’s shape"
  end

  context "a team with scores" do
    setup do
      add_report("Ari Novak", 2, "none", "consistent")
      add_report("Dani Reyes", 2, "some", "consistent")
      add_report("Bea Lindqvist", 3, "consistent", "consistent")
    end

    should "show the team's blades and common gaps, and open the team map" do
      visit_team(DESKTOP_SIZE)

      assert_selector "#team-card [data-team-blades][aria-label='1 of 2 capabilities met as a team']", visible: true
      assert_selector "#team-card [data-team-gap]", text: "Player coach · 2 of 3 short"
      open_team_map
      assert_selector "#team-map [data-team-lane]", count: 2, visible: true
      blades_right = evaluate_script("document.querySelector('#team-map [data-team-blades]').getBoundingClientRect().right")
      lane_left = evaluate_script("document.querySelector('#team-map [data-team-lane]').getBoundingClientRect().left")
      assert_operator blades_right, :<=, lane_left, "expected the blades beside the lanes"

      player_coach = "#team-map [data-team-lane='#{@capabilities.first.stable_id}']"
      assert_selector player_coach, text: "2 short"
      assert_selector "turbo-frame#team-map[complete]", visible: :all
      click_link_with_js_fallback("E3 1", expect_text: "Your 1 direct report at E3")
      assert_selector player_coach, text: /Team 100%.*0 short/
    end

    should "offer Retry when the team map fails to load, and draw the map on it" do
      visit_team(DESKTOP_SIZE)
      wait_for_stimulus "frame-error", scope: "#team-map-modal"
      patch_fetch("team-map", respond: :reject, once: true)

      click_button_with_js_fallback("Open team map", expect_text: "Couldn't load the team map")
      assert_no_selector "#team-map [data-team-lane]"
      execute_script("[...document.querySelectorAll('#team-map-error button')].find((b) => b.textContent.trim() === 'Retry').click()")

      assert_selector "#team-map [data-team-lane]", count: 2, visible: true
      assert_no_selector "#team-map-error", visible: true
    end

    should "keep keyboard focus on the level picked when the map reloads" do
      visit_team(DESKTOP_SIZE)
      open_team_map
      assert_selector "turbo-frame#team-map[complete] a[data-team-level='E3']", visible: true

      execute_script("const link = document.querySelector(\"#team-map a[data-team-level='E3']\"); link.focus(); link.click()")
      assert_text "Your 1 direct report at E3"

      assert_equal "E3", evaluate_script("document.activeElement.dataset.teamLevel")
    end

    should "stack the map's blades above its lanes on a phone" do
      visit_team(MOBILE_SIZE)
      assert_no_sideways_overflow

      open_team_map
      assert_selector "#team-map [data-team-lane]", count: 2, visible: true
      blades_bottom = evaluate_script("document.querySelector('#team-map [data-team-blades]').getBoundingClientRect().bottom")
      lane_top = evaluate_script("document.querySelector('#team-map [data-team-lane]').getBoundingClientRect().top")
      assert_operator blades_bottom, :<=, lane_top, "expected the blades above the lanes"
      assert_compare_control_fits
    end

    should "fit the Compare with control on a phone however long the role's name" do
      ActsAsTenant.with_tenant(@tenant) { @role.update!(name: "Principal Machine Learning Infrastructure Engineer") }
      visit_team(MOBILE_SIZE)

      open_team_map
      assert_selector "#team-map [data-team-lane]", count: 2, visible: true
      assert_compare_control_fits
    end
  end

  should "show a blank slate until two reports have a score, with no team map" do
    add_report("Ari Novak", 2, "consistent", "consistent")
    add_report("Dani Reyes", 2)
    visit_team(MOBILE_SIZE)

    assert_selector "#team-card [data-team-blank]", visible: true
    assert_text "1 of 2 has one so far"
    assert_no_button "Open team map"
    assert_no_sideways_overflow
  end
end
